defmodule Amanogawa.Ingestion.SyncRun do
  @moduledoc """
  Trace of one execution of an ingestion pipeline (`:events` today, `:links`
  and `:summaries` in later issues): status, timestamps, cumulative
  counters, and the resume cursor.

  This is what makes a pipeline run observable (what happened during the
  last sync), resumable (`Amanogawa.Ingestion.Workers.ImportEvents` restarts
  a `:failed` run from `cursor` rather than from scratch), and safe against
  concurrent duplicate runs (the `:events, started_at` index backs a
  "no two `:running` runs of the same kind" check in the `Amanogawa.
  Ingestion` facade).

  The status machine has exactly three states and one legal direction:
  `:running` is the only state a run starts in (`create_changeset/2`);
  `progress_changeset/2` (counters, cursor) only accepts a `:running` run;
  `close_changeset/2` moves a `:running` run to its terminal state
  (`:completed` or `:failed`) and stamps `finished_at`. A terminal run can
  never progress or close again: `changeset.data.status` (the row's status
  *before* this changeset, never the attempted new value) is what every
  transition check reads.

  Internal to the Ingestion context: only `Amanogawa.Ingestion.Workers.
  ImportEvents` and `Amanogawa.Ingestion` (the context facade) touch this
  schema directly.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type kind :: :events | :links | :summaries
  @type status :: :running | :completed | :failed
  @type t :: %__MODULE__{}

  @schema_prefix "ingestion"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "sync_runs" do
    field :kind, Ecto.Enum, values: [:events, :links, :summaries]
    field :status, Ecto.Enum, values: [:running, :completed, :failed]

    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    field :counts, :map, default: %{}
    field :cursor, :map
    field :last_error, :string

    # Options the run was started with (`limit`, `dry_run`, ...), persisted
    # so resuming a failed run replays exactly what was asked initially: a
    # resumed dry run stays a dry run.
    field :options, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Starts a new run: `status` forced to `:running`, `started_at` to now,
  `counts` to `%{}`. `attrs` may set `:kind` (required), `:options` (the
  start options to persist for resumption) and an initial `:cursor`
  (defaults to whatever the schema/database default is, `nil`, when
  omitted).

  Carries the `sync_runs_running_kind_index` unique constraint (at most one
  `:running` run per kind, enforced by a partial index): a concurrent
  insert losing the race surfaces as a changeset error on `:kind` instead
  of a raised constraint violation.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(sync_run, attrs) do
    sync_run
    |> cast(attrs, [:kind, :cursor, :options])
    |> validate_required([:kind])
    |> put_change(:status, :running)
    |> put_change(:started_at, utc_now())
    |> put_change(:counts, %{})
    |> unique_running_constraint()
  end

  @doc """
  Updates the progress (`:counts`, `:cursor`) of a `:running` run. Rejected
  (an error on `:status`) when the run is not currently `:running`.
  """
  @spec progress_changeset(t(), map()) :: Ecto.Changeset.t()
  def progress_changeset(sync_run, attrs) do
    sync_run
    |> cast(attrs, [:counts, :cursor])
    |> require_current_status(:running, "can only progress a running sync run")
  end

  @doc """
  Closes a `:running` run as `:completed` or `:failed` (`attrs.status`),
  stamping `finished_at`. `attrs` may carry `:last_error` (kept `nil` on a
  `:completed` close). Rejected when the run is not currently `:running`,
  or when `attrs.status` is anything other than `:completed`/`:failed`.
  """
  @spec close_changeset(t(), map()) :: Ecto.Changeset.t()
  def close_changeset(sync_run, attrs) do
    sync_run
    |> cast(attrs, [:status, :last_error])
    |> validate_required([:status])
    |> require_current_status(:running, "can only close a running sync run")
    |> validate_terminal_status()
    |> put_change(:finished_at, utc_now())
  end

  @doc """
  Reopens a `:failed` run to `:running`, clearing `last_error` and
  `finished_at`, so `Amanogawa.Ingestion.Workers.ImportEvents` can resume
  it from its existing `cursor` rather than restarting from scratch.
  Rejected when the run is not currently `:failed`, or (through the
  `sync_runs_running_kind_index` unique constraint) when another `:running`
  run of the same kind already exists.
  """
  @spec resume_changeset(t()) :: Ecto.Changeset.t()
  def resume_changeset(sync_run) do
    sync_run
    |> change()
    |> require_current_status(:failed, "can only resume a failed sync run")
    |> put_change(:status, :running)
    |> put_change(:last_error, nil)
    |> put_change(:finished_at, nil)
    |> unique_running_constraint()
  end

  @doc """
  Adds `deltas` (a map of counter name to increment) to `counts`, key by
  key. Used by the import worker to accumulate `pages`, `events_fetched`,
  `events_upserted` and `events_rejected` across pages without losing
  earlier pages' contributions.

      iex> Amanogawa.Ingestion.SyncRun.merge_counts(%{"pages" => 1}, %{"pages" => 1, "events_fetched" => 10})
      %{"pages" => 2, "events_fetched" => 10}

  """
  @spec merge_counts(map(), map()) :: map()
  def merge_counts(counts, deltas) do
    Map.merge(counts, deltas, fn _key, current, delta -> current + delta end)
  end

  defp unique_running_constraint(changeset) do
    unique_constraint(changeset, :kind,
      name: :sync_runs_running_kind_index,
      message: "a running sync run of this kind already exists"
    )
  end

  defp require_current_status(changeset, expected, message) do
    case changeset.data.status do
      ^expected -> changeset
      _ -> add_error(changeset, :status, message)
    end
  end

  # Reads the *effective* status (`get_field/2`: the cast change if any,
  # the row's current value otherwise) rather than `fetch_change/2`: a
  # `close_changeset/2` call that redundantly targets the run's own current
  # status (`status: :running` on an already-`:running` row) casts to no
  # change at all, and must still be rejected rather than silently
  # stamping `finished_at` on a run that never actually closed.
  defp validate_terminal_status(changeset) do
    case get_field(changeset, :status) do
      status when status in [:completed, :failed] -> changeset
      _ -> add_error(changeset, :status, "must be completed or failed")
    end
  end

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
