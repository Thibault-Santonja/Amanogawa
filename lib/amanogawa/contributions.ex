defmodule Amanogawa.Contributions do
  @moduledoc """
  Public API of the Contributions bounded context: the "layered data"
  collaborative editor (issue #034, F08 overview, ADR 0008). Fourth and
  last bounded context of the project (`.claude/rules/architecture.md`,
  PG schema `contributions`: `overrides`, `revisions`, `conflicts`).

  ## The layered-data principle

  Wikidata-sourced data and local contributions never overwrite each
  other silently, in either direction:

    * An ACCEPTED override is the value the map/timeline actually show.
      This module never maintains a second copy of that value: it asks
      `Amanogawa.Atlas.apply_field_override/3` to write it into
      `atlas.events`' own columns and mark the field, so every existing
      read path (`Amanogawa.Atlas.list_events_geojson/1`,
      `get_event_summary/1`, ...) serves the resolved value for free,
      with zero new cost on the read path (`apply_field_override/3`'s
      moduledoc documents this "resolve at write time" decision, ADR
      0009).
    * The monthly Wikidata sync (`Amanogawa.Ingestion.Workers.
      ImportEvents`) never overwrites an accepted override:
      `Amanogawa.Atlas.upsert_events/1` preserves any column whose owning
      field is marked in `overridden_fields` (issue #035). Every
      divergence between Wikidata's incoming value and the override's
      snapshot is journalled instead of silently dropped
      (`record_sync_divergences/1`), so nothing is ever lost, only
      deferred to a reviewer's judgment (`list_open_conflicts/1`,
      `resolve_conflict/3`).

  ## Context boundary (`.claude/rules/architecture.md`)

  `Amanogawa.Atlas.apply_field_override/3` and `release_field_override/3`
  are the ONLY door this context uses to reach into `atlas.events`: never
  `Amanogawa.Repo`, never `Amanogawa.Atlas.Event` or any other internal
  Atlas module. `event_qid` and `author_id` carry no foreign key across
  the schema boundary (existence is checked at the application layer,
  see `propose/3`). Calling `Amanogawa.Accounts.reviewer?/1` and
  `Amanogawa.Ingestion.Workers.ImportEvents` calling
  `record_sync_divergences/1` are both facade-to-facade calls, which the
  architecture rule explicitly allows.

  ## Append-only revisions

  `Amanogawa.Contributions.Revision` rows are never updated nor deleted:
  every mutating function below writes an override/conflict change AND
  its revision in the SAME transaction, and this module exports no
  function that could touch an existing revision row.
  """

  import Ecto.Query

  require Logger

  alias Amanogawa.Accounts
  alias Amanogawa.Atlas
  alias Amanogawa.Contributions.Conflict
  alias Amanogawa.Contributions.Override
  alias Amanogawa.Contributions.ProposalThrottle
  alias Amanogawa.Contributions.Revision
  alias Amanogawa.Repo

  @default_list_limit 50
  @max_list_limit 200

  # ---------------------------------------------------------------------
  # Proposals (issue #034, quota issue #036)
  # ---------------------------------------------------------------------

  @doc """
  Proposes a contribution: `attrs` shaped per `Amanogawa.Contributions.
  Override.propose_changeset/2` (`:kind`, plus the fields the chosen kind
  requires, `:source`), `author_id` the proposing user's id, `ip` the
  proposing client's address.

  Checks `Amanogawa.Contributions.ProposalThrottle.allow?/2` FIRST, before
  any database work (issue #036, `.claude/rules/security.md`): a
  proposal from an over-quota author or client is refused with
  `{:error, :rate_limited}` and nothing is written, whatever `attrs`
  contains. This is the domain invariant, not a UI nicety: the only
  public entry point this context exposes to create a proposal already
  enforces it, so a future caller (a different LiveView, a public API)
  cannot bypass it by construction.

  For `kind: :field`, `attrs.current_value` does not need to be supplied
  by the caller: it is always computed here, from the event's CURRENT
  state read through `Amanogawa.Atlas.get_event_by_qid/1` at THIS moment
  (never trusted from the caller, a value a hostile client could
  otherwise falsify to manufacture a misleading diff for reviewers).

  Writes the override (`:pending`) and its `:proposed` revision in one
  transaction. Returns `{:ok, override}` or `{:error, changeset}`;
  `{:error, :event_not_found}` when `attrs.event_qid` (`kind: :field` or
  `:link`) does not exist locally.
  """
  @spec propose(map(), Ecto.UUID.t(), String.t()) ::
          {:ok, Override.t()}
          | {:error, :event_not_found | :rate_limited | Ecto.Changeset.t()}
  def propose(attrs, author_id, ip) do
    if ProposalThrottle.allow?(author_id, ip) do
      propose(attrs, author_id)
    else
      {:error, :rate_limited}
    end
  end

  @doc """
  The unthrottled proposal write `propose/3` guards with
  `Amanogawa.Contributions.ProposalThrottle` before delegating here.
  Kept public for callers that have already accounted for quota
  themselves (this module's own tests, `Amanogawa.Contributions.
  ProposalThrottle`'s own test suite): every WEB entry point calls
  `propose/3`, never this arity directly, so a hostile client is always
  behind the throttle.
  """
  @spec propose(map(), Ecto.UUID.t()) ::
          {:ok, Override.t()} | {:error, :event_not_found | Ecto.Changeset.t()}
  def propose(attrs, author_id) do
    attrs = Map.new(attrs)

    with {:ok, attrs} <- put_current_value(attrs) do
      %Override{}
      |> Override.propose_changeset(Map.put(attrs, :author_id, author_id))
      |> insert_override_and_revision(author_id)
    end
  end

  defp insert_override_and_revision(changeset, author_id) do
    Repo.transaction(fn -> do_insert_override_and_revision(changeset, author_id) end)
  end

  defp do_insert_override_and_revision(changeset, author_id) do
    with {:ok, override} <- Repo.insert(changeset),
         {:ok, _revision} <- create_revision(override, :proposed, author_id, nil) do
      override
    else
      {:error, error} -> Repo.rollback(error)
    end
  end

  @doc "Fetches an override by id, or `nil` if unknown."
  @spec get_override(Ecto.UUID.t()) :: Override.t() | nil
  def get_override(id), do: Repo.get(Override, id)

  @doc """
  Lists overrides, strictly chronological (most recent first), no
  algorithmic ranking (F08 overview / ADR 0008): `opts` accepts the
  purely factual filters `:status`, `:event_qid`, `:author_id`, plus
  keyset pagination (`:after` - the `{inserted_at, id}` cursor of the
  last row already seen, `:limit` - capped at #{@max_list_limit}).
  """
  @spec list_overrides(map()) :: [Override.t()]
  def list_overrides(opts \\ %{}) do
    Override
    |> filter_eq(:status, Map.get(opts, :status))
    |> filter_eq(:event_qid, Map.get(opts, :event_qid))
    |> filter_eq(:author_id, Map.get(opts, :author_id))
    |> chronological_feed(Map.get(opts, :after))
    |> limit(^list_limit(opts))
    |> Repo.all()
  end

  @doc "Lists an override's revisions, oldest first (its own history in the order it happened)."
  @spec list_revisions(Ecto.UUID.t()) :: [Revision.t()]
  def list_revisions(override_id) do
    Revision
    |> where([r], r.override_id == ^override_id)
    |> order_by([r], asc: r.inserted_at)
    |> Repo.all()
  end

  @doc "Counts overrides by status (`/moderation`'s aggregate, public, factual statistics only)."
  @spec count_by_status() :: %{Override.status() => non_neg_integer()}
  def count_by_status do
    Override
    |> group_by([o], o.status)
    |> select([o], {o.status, count()})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Accepts a `:pending` override: verified independently of whatever the
  router/LiveView already checked (`.claude/rules/security.md`:
  "revérifié côté domaine, jamais seulement dans le routeur"), `reviewer`
  must hold the `:reviewer` role (`Amanogawa.Accounts.reviewer?/1`) and
  must not be the override's own author (anti self-review). `message` is
  the reviewer's public motive, mandatory and bounded.

  Snapshots `wikidata_value_at_acceptance` from the event's CURRENT state
  (read at this moment, not at proposal time: a sync may have run in
  between), applies the correction through `Amanogawa.Atlas.
  apply_field_override/3` (`kind: :field`), `Amanogawa.Atlas.
  upsert_event_links/1` (`kind: :link`) or `create_contributed_event/1`
  (`kind: :new_event`), moves the override to `:accepted`, and journals
  an `:accepted` revision, all in one transaction with the override
  RELOADED under that transaction (a concurrent second acceptance of the
  same override sees the reloaded `:accepted` status and is rejected,
  applying Atlas exactly once regardless of how many requests race).

  A single sober decision email is sent to the author AFTER the
  transaction commits (issue #037, `Amanogawa.Contributions.
  DecisionNotifier`): never for a decision the transaction itself rolled
  back, never a second time for the same acceptance.
  """
  @spec accept_override(Ecto.UUID.t(), Accounts.User.t(), String.t()) ::
          {:ok, Override.t()}
          | {:error,
             :not_found
             | :forbidden
             | :self_review
             | :not_pending
             | :message_required
             | Ecto.Changeset.t()}
  def accept_override(override_id, reviewer, message) do
    with :ok <- validate_reviewer_message(message),
         {:ok, updated} <-
           with_reviewer_authority(
             override_id,
             reviewer,
             &do_accept_override(&1, reviewer, message)
           ) do
      notify_decision(updated, :accepted, message)
      {:ok, updated}
    end
  end

  defp do_accept_override(override, reviewer, message) do
    with {:ok, wikidata_value} <- current_field_snapshot(override),
         {:ok, _applied} <- apply_override(override),
         {:ok, updated} <- override |> Override.accept_changeset(wikidata_value) |> Repo.update(),
         {:ok, _revision} <- create_revision(updated, :accepted, reviewer.id, message) do
      {:ok, updated}
    end
  end

  @doc """
  Rejects a `:pending` override: same reviewer/self-review/message
  contract as `accept_override/3`, but writes nothing to `Amanogawa.Atlas`
  (a rejected proposal never touched the map). Moves the override to
  `:rejected` and journals a `:rejected` revision. Same post-commit
  decision email as `accept_override/3`.
  """
  @spec reject_override(Ecto.UUID.t(), Accounts.User.t(), String.t()) ::
          {:ok, Override.t()}
          | {:error,
             :not_found
             | :forbidden
             | :self_review
             | :not_pending
             | :message_required
             | Ecto.Changeset.t()}
  def reject_override(override_id, reviewer, message) do
    with :ok <- validate_reviewer_message(message),
         {:ok, updated} <-
           with_reviewer_authority(
             override_id,
             reviewer,
             &do_reject_override(&1, reviewer, message)
           ) do
      notify_decision(updated, :rejected, message)
      {:ok, updated}
    end
  end

  defp do_reject_override(override, reviewer, message) do
    with {:ok, updated} <- override |> Override.reject_changeset() |> Repo.update(),
         {:ok, _revision} <- create_revision(updated, :rejected, reviewer.id, message) do
      {:ok, updated}
    end
  end

  # ---------------------------------------------------------------------
  # Appeals (issue #037)
  # ---------------------------------------------------------------------

  @appeal_text_min_length 5
  @appeal_text_max_length 1000

  @doc """
  Appeals a `:rejected` override: `author` must be the override's own
  author (anti-IDOR, `.claude/rules/security.md`), and this can only ever
  happen ONCE per override (a second call, even by the same author,
  fails with `:already_appealed`). `text` is the author's public reply,
  mandatory, #{@appeal_text_min_length}-#{@appeal_text_max_length}
  characters.

  Moves the override to `:appealed` (a state `Amanogawa.Contributions.
  list_review_queue/1` surfaces alongside `:pending`, at its ORIGINAL
  proposal date: an appeal never "jumps the queue") and journals an
  `:appealed` revision carrying `text`. No email is sent here (issue
  #037: notifications happen at a decision, an appeal is the author
  speaking, not a reviewer deciding).
  """
  @spec appeal_override(Ecto.UUID.t(), Accounts.User.t(), String.t()) ::
          {:ok, Override.t()}
          | {:error,
             :not_found
             | :forbidden
             | :not_rejected
             | :already_appealed
             | :text_required
             | Ecto.Changeset.t()}
  def appeal_override(override_id, author, text) do
    with :ok <- validate_appeal_text(text) do
      Repo.transaction(fn -> do_appeal_override(override_id, author, text) end)
    end
  end

  defp do_appeal_override(override_id, author, text) do
    case locked_override(override_id) do
      nil ->
        Repo.rollback(:not_found)

      override ->
        authorize_and_run(
          override,
          author,
          &do_appeal_write(&1, author, text),
          &authorize_appeal/2
        )
    end
  end

  defp do_appeal_write(override, author, text) do
    with {:ok, updated} <- override |> Override.appeal_changeset() |> Repo.update(),
         {:ok, _revision} <- create_revision(updated, :appealed, author.id, text) do
      {:ok, updated}
    end
  end

  defp authorize_appeal(override, author) do
    cond do
      override.status != :rejected -> {:error, :not_rejected}
      override.author_id != author.id -> {:error, :forbidden}
      already_appealed?(override.id) -> {:error, :already_appealed}
      true -> :ok
    end
  end

  @doc """
  The final decision on an appealed (`:appealed`) override: `reviewer`
  must hold the `:reviewer` role and must not be the override's own
  author (same anti self-review contract as `accept_override/3`; the
  SAME reviewer who made the original decision is explicitly allowed to
  also decide the appeal, F08 overview's "en V1 le même est accepté :
  projet solo"). `attrs` carries `:decision` (`:accepted` applies the
  override exactly like `accept_override/3`, `:rejected` leaves
  `Amanogawa.Atlas` untouched) and `:message` (mandatory, bounded public
  motive).

  Journals an `:appeal_reviewed` revision. After this, the override is
  terminal: `appeal_override/3` never accepts a second appeal on it
  (`already_appealed?/1` finds this very `:appealed` revision). Same
  post-commit decision email as `accept_override/3` (`:appeal_accepted`
  or `:appeal_rejected`).
  """
  @spec review_appeal(Ecto.UUID.t(), Accounts.User.t(), map()) ::
          {:ok, Override.t()}
          | {:error,
             :not_found
             | :forbidden
             | :self_review
             | :not_appealed
             | :message_required
             | Ecto.Changeset.t()}
  def review_appeal(override_id, reviewer, attrs) do
    decision = Map.fetch!(attrs, :decision)
    message = Map.fetch!(attrs, :message)

    with :ok <- validate_reviewer_message(message),
         {:ok, updated} <-
           with_appeal_authority(
             override_id,
             reviewer,
             &do_review_appeal(&1, reviewer, decision, message)
           ) do
      notify_decision(updated, appeal_outcome(decision), message)
      {:ok, updated}
    end
  end

  defp with_appeal_authority(override_id, reviewer, fun) do
    Repo.transaction(fn -> do_with_appeal_authority(override_id, reviewer, fun) end)
  end

  defp do_with_appeal_authority(override_id, reviewer, fun) do
    case locked_override(override_id) do
      nil -> Repo.rollback(:not_found)
      override -> authorize_and_run(override, reviewer, fun, &authorize_appeal_reviewer/2)
    end
  end

  defp authorize_appeal_reviewer(override, reviewer) do
    cond do
      override.status != :appealed -> {:error, :not_appealed}
      not Accounts.reviewer?(reviewer) -> {:error, :forbidden}
      override.author_id == reviewer.id -> {:error, :self_review}
      true -> :ok
    end
  end

  defp do_review_appeal(override, reviewer, :accepted, message) do
    with {:ok, wikidata_value} <- current_field_snapshot(override),
         {:ok, _applied} <- apply_override(override),
         {:ok, updated} <- override |> Override.accept_changeset(wikidata_value) |> Repo.update(),
         {:ok, _revision} <- create_revision(updated, :appeal_reviewed, reviewer.id, message) do
      {:ok, updated}
    end
  end

  defp do_review_appeal(override, reviewer, :rejected, message) do
    with {:ok, updated} <- override |> Override.reject_changeset() |> Repo.update(),
         {:ok, _revision} <- create_revision(updated, :appeal_reviewed, reviewer.id, message) do
      {:ok, updated}
    end
  end

  defp appeal_outcome(:accepted), do: :appeal_accepted
  defp appeal_outcome(:rejected), do: :appeal_rejected

  @doc """
  The review queue (issue #037): every `:pending` or `:appealed`
  override, STRICTLY chronological by proposal date (`inserted_at`
  ascending, FIFO: the oldest proposal first, no algorithmic
  prioritization, F08 overview's anti-dark-patterns principle). An appeal
  keeps its override's ORIGINAL `inserted_at`, so it never jumps ahead of
  older still-pending proposals.

  `opts` accepts the purely factual filters `:kind`, `:event_qid`, plus
  keyset pagination (`:after`, `:limit`), same shape as `list_overrides/1`.
  """
  @spec list_review_queue(map()) :: [Override.t()]
  def list_review_queue(opts \\ %{}) do
    Override
    |> where([o], o.status in [:pending, :appealed])
    |> filter_eq(:kind, Map.get(opts, :kind))
    |> filter_eq(:event_qid, Map.get(opts, :event_qid))
    |> review_queue_order(Map.get(opts, :after))
    |> limit(^list_limit(opts))
    |> Repo.all()
  end

  defp review_queue_order(query, nil) do
    order_by(query, [o], asc: o.inserted_at, asc: o.id)
  end

  defp review_queue_order(query, %{inserted_at: inserted_at, id: id}) do
    query
    |> where([o], o.inserted_at > ^inserted_at or (o.inserted_at == ^inserted_at and o.id > ^id))
    |> order_by([o], asc: o.inserted_at, asc: o.id)
  end

  defp already_appealed?(override_id) do
    Revision
    |> where([r], r.override_id == ^override_id and r.action == :appealed)
    |> Repo.exists?()
  end

  defp validate_appeal_text(text) do
    if is_binary(text) and String.length(String.trim(text)) >= @appeal_text_min_length and
         String.length(text) <= @appeal_text_max_length do
      :ok
    else
      {:error, :text_required}
    end
  end

  # ---------------------------------------------------------------------
  # Private: decision notifications (issue #037)
  # ---------------------------------------------------------------------

  # `override.author_id` is `nil` only after issue #038's account
  # anonymization ships: no email exists to reach, so notification is a
  # silent no-op, never an error (the decision itself already committed).
  defp notify_decision(%Override{author_id: nil}, _outcome, _message), do: :ok

  defp notify_decision(override, outcome, message) do
    user = Accounts.get_user!(override.author_id)
    path = contribution_path(override.id)

    case notifier().deliver(user.email, outcome, message, path, "fr") do
      :ok ->
        :ok

      {:error, reason} ->
        # Bounded tag only, same rationale as `Amanogawa.Accounts.
        # send_magic_link/3`: never log a raw SMTP error, which can embed
        # the whole outgoing message.
        Logger.error("decision notification delivery failed: #{delivery_error_tag(reason)}")
        :ok
    end
  end

  defp contribution_path(override_id), do: "/contributions/" <> override_id

  defp delivery_error_tag(reason) when is_atom(reason), do: inspect(reason)
  defp delivery_error_tag(%struct{}), do: inspect(struct)
  defp delivery_error_tag(_reason), do: "unexpected error"

  defp notifier, do: Application.get_env(:amanogawa, :decision_notifier)

  # ---------------------------------------------------------------------
  # Sync coexistence and conflicts (issue #035)
  # ---------------------------------------------------------------------

  @doc """
  Compares `lot` (the SAME normalized attrs maps `Amanogawa.Atlas.
  upsert_events/1` was just called with, not a fresh database read: "le
  lot porte ce que Wikidata voulait écrire", F08 overview) against every
  `:accepted` override whose `event_qid` appears in it, in ONE query when
  no such override exists (the common case, issue #035's limit-case
  test).

  For each matching override, the incoming value for its field is
  compared, on a normalized payload, against `wikidata_value_at_acceptance`:

    * equal: nothing (Wikidata has not moved on this field since
      acceptance).
    * equal to the override's own `proposed_value` (`:position` compared
      on coordinates alone, `location_source` excluded: a resolution
      method changing alone is not "Wikidata rejoining the correction"):
      Wikidata rejoined the correction. The override moves to
      `:superseded`, `Amanogawa.Atlas.release_field_override/3` restores
      the (now-identical) value and lifts the marker, a `:superseded`
      revision is journalled.
    * anything else: an open conflict for this override is created or, if
      one is already open, refreshed (`wikidata_value`, `detected_at`)
      instead of duplicated (`conflicts_one_open_per_override`).

  Returns `%{unchanged:, superseded:, conflicts_opened:,
  conflicts_refreshed:}`, folded into the calling `Amanogawa.Ingestion.
  Workers.ImportEvents` job's `SyncRun` counters.
  """
  @spec record_sync_divergences([map()]) :: %{
          unchanged: non_neg_integer(),
          superseded: non_neg_integer(),
          conflicts_opened: non_neg_integer(),
          conflicts_refreshed: non_neg_integer()
        }
  def record_sync_divergences(lot) when is_list(lot) do
    qids = lot |> Enum.map(&Map.fetch!(&1, :qid)) |> Enum.uniq()

    Override
    |> where([o], o.status == :accepted and o.kind == :field and o.event_qid in ^qids)
    |> Repo.all()
    |> Enum.reduce(empty_divergence_counts(), fn override, counts ->
      lot_entry = Enum.find(lot, &(Map.fetch!(&1, :qid) == override.event_qid))
      apply_divergence(override, lot_entry, counts)
    end)
  end

  @doc """
  Lists conflicts still `:open`, strictly chronological
  (`Amanogawa.Contributions.Conflict.detected_at` ascending: the oldest
  divergence is examined first).
  """
  @spec list_open_conflicts(map()) :: [Conflict.t()]
  def list_open_conflicts(opts \\ %{}) do
    Conflict
    |> where([c], c.status == :open)
    |> order_by([c], asc: c.detected_at)
    |> limit(^list_limit(opts))
    |> Repo.all()
  end

  @doc """
  Resolves an open conflict: `reviewer` must hold the `:reviewer` role
  (revalidated here, same contract as `accept_override/3`); `attrs`
  carries `:resolution` (`:kept_override` keeps the correction and
  refreshes the override's Wikidata snapshot so the same divergence does
  not re-signal on the next sync, `:adopted_wikidata` releases the field
  back to Wikidata's value and moves the override to `:superseded`) and
  `:message` (the reviewer's public motive, mandatory and bounded by
  `Amanogawa.Contributions.Conflict.reason_max_length/0`).

  Transactional: the conflict, the override (when relevant) and the
  revision are all written together. Rejected, with no effect on any
  table, for an unknown or already-resolved conflict
  (`{:error, :not_found}` / `{:error, :already_resolved}`), a non-reviewer
  (`{:error, :forbidden}`), or a missing/blank/oversized message
  (`{:error, :message_required}`).
  """
  @spec resolve_conflict(Ecto.UUID.t(), Accounts.User.t(), map()) ::
          {:ok, Conflict.t()}
          | {:error, :not_found | :already_resolved | :forbidden | :message_required}
  def resolve_conflict(conflict_id, reviewer, attrs) do
    resolution = Map.fetch!(attrs, :resolution)
    message = Map.fetch!(attrs, :message)

    with :ok <- validate_reviewer_message(message) do
      Conflict
      |> Repo.get(conflict_id)
      |> resolve_open_conflict(resolution, reviewer, message)
    end
  end

  defp resolve_open_conflict(nil, _resolution, _reviewer, _message), do: {:error, :not_found}

  defp resolve_open_conflict(%Conflict{status: :resolved}, _resolution, _reviewer, _message),
    do: {:error, :already_resolved}

  defp resolve_open_conflict(conflict, resolution, reviewer, message) do
    if Accounts.reviewer?(reviewer) do
      do_resolve_conflict(conflict, resolution, reviewer, message)
    else
      {:error, :forbidden}
    end
  end

  # ---------------------------------------------------------------------
  # Private: proposals
  # ---------------------------------------------------------------------

  defp put_current_value(%{kind: :field, event_qid: qid, field: field} = attrs) do
    case Atlas.get_event_by_qid(qid) do
      nil -> {:error, :event_not_found}
      event -> {:ok, Map.put(attrs, :current_value, field_payload(field, event))}
    end
  end

  # Both endpoints must exist locally (issue #036's own "existence
  # vérifiée via Atlas.get_event_by_qid/1"): a link naming an unknown
  # target is rejected here, before any write, exactly like an unknown
  # source `event_qid` above.
  defp put_current_value(%{kind: :link, event_qid: qid, target_qid: target_qid} = attrs)
       when not is_nil(qid) do
    with {:ok, _event} <- fetch_local_event(qid),
         {:ok, _target} <- fetch_local_event(target_qid) do
      {:ok, attrs}
    end
  end

  defp put_current_value(attrs), do: {:ok, attrs}

  defp fetch_local_event(qid) do
    case Atlas.get_event_by_qid(qid) do
      nil -> {:error, :event_not_found}
      event -> {:ok, event}
    end
  end

  defp create_revision(override, action, actor_id, message) do
    %Revision{}
    |> Revision.create_changeset(%{
      override_id: override.id,
      action: action,
      actor_id: actor_id,
      message: message
    })
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------
  # Private: accept/reject
  # ---------------------------------------------------------------------

  defp with_reviewer_authority(override_id, reviewer, fun) do
    Repo.transaction(fn -> do_with_reviewer_authority(override_id, reviewer, fun) end)
  end

  defp do_with_reviewer_authority(override_id, reviewer, fun) do
    case locked_override(override_id) do
      nil -> Repo.rollback(:not_found)
      override -> authorize_and_run(override, reviewer, fun, &authorize_reviewer/2)
    end
  end

  defp locked_override(override_id) do
    Override
    |> where([o], o.id == ^override_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp authorize_and_run(override, actor, fun, authorize_fun) do
    with :ok <- authorize_fun.(override, actor),
         {:ok, result} <- fun.(override) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # A reviewer's decision motive is mandatory and bounded (F08 overview:
  # "accepte ou rejette avec motif public"), checked BEFORE any database
  # work: a blank or missing motive costs nothing, not even the
  # transaction that would otherwise open and immediately roll back.
  @reviewer_message_max_length 1000

  defp validate_reviewer_message(message) do
    if is_binary(message) and String.trim(message) != "" and
         String.length(message) <= @reviewer_message_max_length do
      :ok
    else
      {:error, :message_required}
    end
  end

  defp authorize_reviewer(override, reviewer) do
    cond do
      override.status != :pending -> {:error, :not_pending}
      not Accounts.reviewer?(reviewer) -> {:error, :forbidden}
      override.author_id == reviewer.id -> {:error, :self_review}
      true -> :ok
    end
  end

  defp current_field_snapshot(%Override{kind: :field, event_qid: qid, field: field}) do
    case Atlas.get_event_by_qid(qid) do
      nil -> {:error, :event_not_found}
      event -> {:ok, field_payload(field, event)}
    end
  end

  defp current_field_snapshot(%Override{}), do: {:ok, nil}

  defp apply_override(%Override{kind: :field} = override) do
    Atlas.apply_field_override(override.event_qid, override.field, override.proposed_value)
  end

  defp apply_override(%Override{kind: :link} = override) do
    Atlas.upsert_event_links([
      %{source_qid: override.event_qid, target_qid: override.target_qid, type: override.link_type}
    ])
  end

  defp apply_override(%Override{kind: :new_event} = override) do
    Atlas.create_contributed_event(new_event_attrs(override.proposed_value))
  end

  defp new_event_attrs(payload) do
    begin = Map.fetch!(payload, "begin_date")
    position = Map.fetch!(payload, "position")

    %{
      label_fr: Map.get(payload, "label_fr"),
      label_en: Map.get(payload, "label_en"),
      description_fr: Map.get(payload, "description_fr"),
      description_en: Map.get(payload, "description_en"),
      begin_year: Map.fetch!(begin, "year"),
      begin_month: Map.get(begin, "month"),
      begin_day: Map.get(begin, "day"),
      begin_precision: Map.fetch!(begin, "precision"),
      begin_calendar: begin |> Map.get("calendar") |> calendar_atom(),
      geom: %Geo.Point{
        coordinates: {Map.fetch!(position, "lon") / 1, Map.fetch!(position, "lat") / 1},
        srid: 4326
      },
      location_source: :contribution
    }
  end

  # ---------------------------------------------------------------------
  # Private: sync divergences (issue #035)
  # ---------------------------------------------------------------------

  defp empty_divergence_counts,
    do: %{unchanged: 0, superseded: 0, conflicts_opened: 0, conflicts_refreshed: 0}

  defp apply_divergence(_override, nil, counts), do: counts

  defp apply_divergence(override, lot_entry, counts) do
    incoming = field_payload(override.field, lot_entry)

    cond do
      incoming == override.wikidata_value_at_acceptance ->
        Map.update!(counts, :unchanged, &(&1 + 1))

      matches_proposed?(override.field, incoming, override.proposed_value) ->
        supersede_override(override, incoming)
        Map.update!(counts, :superseded, &(&1 + 1))

      true ->
        open_or_refresh_conflict(override, incoming, counts)
    end
  end

  defp matches_proposed?(:position, incoming, proposed) do
    Map.take(incoming, ["lon", "lat"]) == Map.take(proposed, ["lon", "lat"])
  end

  defp matches_proposed?(_field, incoming, proposed), do: incoming == proposed

  defp supersede_override(override, incoming) do
    Repo.transaction(fn ->
      {:ok, _event} = Atlas.release_field_override(override.event_qid, override.field, incoming)
      updated = override |> Override.supersede_changeset() |> Repo.update!()
      {:ok, _revision} = create_revision(updated, :superseded, nil, nil)
      updated
    end)
  end

  defp open_or_refresh_conflict(override, incoming, counts) do
    now = utc_now()

    case Repo.get_by(Conflict, override_id: override.id, status: :open) do
      nil ->
        %Conflict{}
        |> Conflict.open_changeset(%{
          override_id: override.id,
          event_qid: override.event_qid,
          field: override.field,
          wikidata_value: incoming,
          detected_at: now
        })
        |> Repo.insert!()

        Map.update!(counts, :conflicts_opened, &(&1 + 1))

      conflict ->
        conflict
        |> Conflict.refresh_changeset(%{wikidata_value: incoming, detected_at: now})
        |> Repo.update!()

        Map.update!(counts, :conflicts_refreshed, &(&1 + 1))
    end
  end

  defp do_resolve_conflict(conflict, :kept_override, reviewer, message) do
    Repo.transaction(fn ->
      override = Repo.get!(Override, conflict.override_id)

      override
      |> Override.refresh_snapshot_changeset(conflict.wikidata_value)
      |> Repo.update!()

      resolved =
        conflict
        |> Conflict.resolve_changeset(%{resolution: :kept_override, resolved_by: reviewer.id})
        |> Repo.update!()

      {:ok, _revision} = create_revision(override, :conflict_resolved, reviewer.id, message)
      resolved
    end)
  end

  defp do_resolve_conflict(conflict, :adopted_wikidata, reviewer, message) do
    Repo.transaction(fn ->
      override = Repo.get!(Override, conflict.override_id)

      {:ok, _event} =
        Atlas.release_field_override(override.event_qid, override.field, conflict.wikidata_value)

      updated_override = override |> Override.supersede_changeset() |> Repo.update!()

      resolved =
        conflict
        |> Conflict.resolve_changeset(%{resolution: :adopted_wikidata, resolved_by: reviewer.id})
        |> Repo.update!()

      {:ok, _revision} = create_revision(updated_override, :superseded, reviewer.id, message)
      resolved
    end)
  end

  # ---------------------------------------------------------------------
  # Private: field <-> jsonb payload (mirrors, but never calls,
  # `Amanogawa.Atlas.OverridableField`, see this module's and `Override`'s
  # moduledocs for why the two cannot share code across the context
  # boundary)
  # ---------------------------------------------------------------------

  defp field_payload(:label_fr, source), do: %{"value" => Map.fetch!(source, :label_fr)}
  defp field_payload(:label_en, source), do: %{"value" => Map.fetch!(source, :label_en)}
  defp field_payload(:begin_date, source), do: date_payload(source, :begin)
  defp field_payload(:end_date, source), do: date_payload(source, :end)
  defp field_payload(:position, source), do: position_payload(source)

  defp date_payload(source, :begin) do
    build_date_payload(
      Map.fetch!(source, :begin_year),
      Map.fetch!(source, :begin_month),
      Map.fetch!(source, :begin_day),
      Map.fetch!(source, :begin_precision),
      Map.fetch!(source, :begin_calendar)
    )
  end

  defp date_payload(source, :end) do
    build_date_payload(
      Map.fetch!(source, :end_year),
      Map.fetch!(source, :end_month),
      Map.fetch!(source, :end_day),
      Map.fetch!(source, :end_precision),
      Map.fetch!(source, :end_calendar)
    )
  end

  # No date at all (most events have no end date): represented as `nil`,
  # never as a payload map with a `nil` year (which would fail
  # `Amanogawa.HistoricalDate`'s own required-year invariant if ever
  # replayed through it).
  defp build_date_payload(nil, _month, _day, _precision, _calendar), do: nil

  defp build_date_payload(year, month, day, precision, calendar) do
    %{
      "year" => year,
      "month" => month,
      "day" => day,
      "precision" => precision,
      "calendar" => calendar_string(calendar)
    }
  end

  defp calendar_string(nil), do: nil
  defp calendar_string(calendar) when is_atom(calendar), do: Atom.to_string(calendar)

  defp calendar_atom(nil), do: nil
  defp calendar_atom("gregorian"), do: :gregorian
  defp calendar_atom("julian"), do: :julian

  # No geometry at all (an event ingested without a resolvable position):
  # represented as `nil`, mirroring `build_date_payload/5`'s "absent
  # value" convention.
  defp position_payload(source) do
    case Map.fetch!(source, :geom) do
      nil ->
        nil

      %Geo.Point{coordinates: {lon, lat}} ->
        %{
          "lon" => round_coord(lon),
          "lat" => round_coord(lat),
          "location_source" => source |> Map.fetch!(:location_source) |> Atom.to_string()
        }
    end
  end

  # Rounded to 6 decimal digits (~11cm at the equator): a coordinate
  # round-tripped through jsonb must compare equal to itself
  # (`record_sync_divergences/1`'s "unchanged" check) regardless of
  # floating-point representation noise, per this issue's own point
  # d'attention ("coordonnées arrondies à l'identique").
  defp round_coord(value), do: Float.round(value / 1, 6)

  # ---------------------------------------------------------------------
  # Private: listing
  # ---------------------------------------------------------------------

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, field, value), do: where(query, [o], field(o, ^field) == ^value)

  defp chronological_feed(query, nil) do
    order_by(query, [o], desc: o.inserted_at, desc: o.id)
  end

  defp chronological_feed(query, %{inserted_at: inserted_at, id: id}) do
    query
    |> where([o], o.inserted_at < ^inserted_at or (o.inserted_at == ^inserted_at and o.id < ^id))
    |> order_by([o], desc: o.inserted_at, desc: o.id)
  end

  defp list_limit(opts), do: opts |> Map.get(:limit, @default_list_limit) |> min(@max_list_limit)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
