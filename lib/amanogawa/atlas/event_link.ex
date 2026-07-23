defmodule Amanogawa.Atlas.EventLink do
  @moduledoc """
  A typed, directed edge between two `Amanogawa.Atlas.Event` rows.

  `type` is one of `:part_of`, `:follows`, `:cause`, `:effect`,
  `:significant`. The triple `(source_id, target_id, type)` is unique, which
  is what makes `Amanogawa.Atlas.upsert_event_links/1`'s bulk
  `on_conflict: :nothing` insert idempotent.

  Internal to the Atlas context: only `Amanogawa.Atlas` is called from other
  contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type link_type :: :part_of | :follows | :cause | :effect | :significant

  @schema_prefix "atlas"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
  @foreign_key_type :binary_id

  schema "event_links" do
    belongs_to :source, Amanogawa.Atlas.Event
    belongs_to :target, Amanogawa.Atlas.Event
    field :type, Ecto.Enum, values: [:part_of, :follows, :cause, :effect, :significant]

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds and validates a changeset. Rejects an auto-link (`source_id ==
  target_id`); the `(source_id, target_id, type)` unique constraint is
  enforced at the database level via `unique_constraint/3`.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event_link, attrs) do
    event_link
    |> cast(attrs, [:source_id, :target_id, :type])
    |> validate_required([:source_id, :target_id, :type])
    |> validate_not_self_link()
    |> unique_constraint([:source_id, :target_id, :type],
      name: :event_links_source_id_target_id_type_index
    )
    |> foreign_key_constraint(:source_id)
    |> foreign_key_constraint(:target_id)
  end

  defp validate_not_self_link(changeset) do
    case {get_field(changeset, :source_id), get_field(changeset, :target_id)} do
      {same, same} when not is_nil(same) ->
        add_error(changeset, :target_id, "cannot link an event to itself")

      _ ->
        changeset
    end
  end
end
