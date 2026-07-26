defmodule Amanogawa.Contributions.Conflict do
  @moduledoc """
  A divergence the monthly Wikidata sync detects between its incoming
  value and the snapshot of an ACCEPTED override (issue #035, F08
  overview: "la sync mensuelle... journalise les divergences dans
  contributions.conflicts, table à examiner par les relecteurs").

  `Amanogawa.Contributions.record_sync_divergences/1` is the only writer
  of fresh rows and refreshes; `Amanogawa.Contributions.resolve_conflict/3`
  is the only writer of a resolution. At most one `status: :open` row per
  `override_id` (`conflicts_one_open_per_override`, a partial unique
  index): a repeated sync divergence on the same field refreshes this one
  row (`wikidata_value`, `detected_at`) rather than piling up duplicates.

  ## Absent Wikidata value

  `wikidata_value` is `NOT NULL`: when Wikidata carries NO value at all
  for the field (e.g. it removed an end date the accepted override still
  corrects), the absence is represented as `%{"absent" => true}`, the one
  reserved payload shape no real field value can collide with (every real
  payload carries at least a `"value"`, date, or coordinate key). Readers
  resolve it back to `nil` (`Amanogawa.Contributions`' own
  `from_conflict_value/1`) before releasing a field or refreshing a
  snapshot.

  ## System resolution

  `:obsolete` is the SYSTEM resolution (`resolved_by: nil`): written when
  the override's own lifecycle makes an open conflict moot (the override
  left `:accepted`, or the sync observed the divergence has vanished),
  never by a reviewer's explicit decision. Reviewers only ever write
  `:kept_override` or `:adopted_wikidata`.

  `override_id` carries a foreign key (intra-context, both tables live in
  the `contributions` PG schema); `resolved_by` does not (same reasoning
  as `Amanogawa.Contributions.Override.author_id`).

  Internal to the Contributions context: only `Amanogawa.Contributions` is
  called from other contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Amanogawa.Contributions.Override

  @type t :: %__MODULE__{}
  @type status :: :open | :resolved
  @type resolution :: :kept_override | :adopted_wikidata | :obsolete

  @schema_prefix "contributions"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
  @foreign_key_type :binary_id

  @reasons_max_length 1000

  schema "conflicts" do
    belongs_to :override, Override
    field :event_qid, :string
    field :field, Ecto.Enum, values: Override.field_names()
    field :wikidata_value, :map
    field :detected_at, :utc_datetime
    field :status, Ecto.Enum, values: [:open, :resolved], default: :open
    field :resolution, Ecto.Enum, values: [:kept_override, :adopted_wikidata, :obsolete]
    field :resolved_by, :binary_id
    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds the changeset for a fresh open conflict
  (`Amanogawa.Contributions.record_sync_divergences/1`, the "conflict
  opened" case).
  """
  @spec open_changeset(t(), map()) :: Ecto.Changeset.t()
  def open_changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [:override_id, :event_qid, :field, :wikidata_value, :detected_at])
    |> validate_required([:override_id, :event_qid, :field, :wikidata_value, :detected_at])
    |> put_change(:status, :open)
    |> foreign_key_constraint(:override_id)
    |> unique_constraint(:override_id, name: :conflicts_one_open_per_override)
  end

  @doc """
  Builds the changeset that refreshes an already-open conflict with a new
  incoming Wikidata value and detection timestamp (the "conflict
  refreshed" case): the same divergence recurring across syncs updates
  this one row instead of opening a second one.
  """
  @spec refresh_changeset(t(), map()) :: Ecto.Changeset.t()
  def refresh_changeset(conflict, attrs) do
    cast(conflict, attrs, [:wikidata_value, :detected_at])
  end

  @doc """
  Builds the changeset `Amanogawa.Contributions.resolve_conflict/3` writes
  through: moves `status` to `:resolved`, stamps `resolution`,
  `resolved_by` and `resolved_at`. Rejected (an error on `:status`) when
  the conflict is not currently `:open`, so a conflict can never be
  resolved twice.
  """
  @spec resolve_changeset(t(), map()) :: Ecto.Changeset.t()
  def resolve_changeset(conflict, attrs) do
    conflict
    |> cast(attrs, [:resolution, :resolved_by])
    |> validate_required([:resolution])
    |> require_open_status()
    |> put_change(:status, :resolved)
    |> put_change(:resolved_at, DateTime.truncate(DateTime.utc_now(), :second))
  end

  defp require_open_status(changeset) do
    case changeset.data.status do
      :open -> changeset
      _ -> add_error(changeset, :status, "can only resolve an open conflict")
    end
  end

  @doc "Bounded length for a conflict resolution's public motive (stored as a revision message)."
  @spec reason_max_length() :: pos_integer()
  def reason_max_length, do: @reasons_max_length
end
