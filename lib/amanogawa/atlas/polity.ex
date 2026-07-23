defmodule Amanogawa.Atlas.Polity do
  @moduledoc """
  A named political entity (kingdom, empire, city-state, ...) as recorded by
  one border source (Cliopatria, historical-basemaps, ...).

  Identity is the natural key `(name, source)`, not a stable external id:
  neither Cliopatria nor historical-basemaps assigns one, and the same
  entity name can legitimately appear under two different sources without
  being the same row (`Amanogawa.Atlas.upsert_polity/1`'s conflict target).
  `from_year`/`to_year` describe the entity's own attested existence span
  when the source states one; they are nullable, unlike `Amanogawa.Atlas.
  Border`'s own `from_year`/`to_year` (always required there): a polity can
  be known only through its dated `borders` rows, with no separate overall
  span in the source data.

  Internal to the Atlas context: only `Amanogawa.Atlas` is called from
  other contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @schema_prefix "atlas"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "polities" do
    field :name, :string
    field :from_year, :integer
    field :to_year, :integer
    field :source, :string

    timestamps(type: :utc_datetime)
  end

  @castable_fields [:name, :from_year, :to_year, :source]

  # Mirrors `Amanogawa.Ingestion.Borders.FeatureValidation.max_name_length/0`
  # (the ingestion-side guard): the changeset is the write boundary's own
  # defense in depth, so a hostile name can never reach storage even
  # through a future caller that skips the parser.
  @max_name_length 500

  @doc """
  Builds and validates a changeset. `name` and `source` are required (the
  natural key); `name` is capped at #{@max_name_length} characters
  (matching the ingestion parsers' own rejection threshold);
  `from_year <= to_year` is enforced only when both are present, since
  either may be unknown independently.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(polity, attrs) do
    polity
    |> cast(attrs, @castable_fields)
    |> validate_required([:name, :source])
    |> validate_length(:name, max: @max_name_length)
    |> unique_constraint([:name, :source])
    |> validate_year_order()
  end

  defp validate_year_order(changeset) do
    with from_year when not is_nil(from_year) <- get_field(changeset, :from_year),
         to_year when not is_nil(to_year) <- get_field(changeset, :to_year),
         true <- from_year > to_year do
      add_error(changeset, :to_year, "must be greater than or equal to from_year")
    else
      _ -> changeset
    end
  end
end
