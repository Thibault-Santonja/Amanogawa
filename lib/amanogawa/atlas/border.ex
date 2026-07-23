defmodule Amanogawa.Atlas.Border do
  @moduledoc """
  A dated polygon (a "zone of influence", ADR 0004: historical borders are
  academically disputed and rendered as such, not as exact lines) belonging
  to a `Amanogawa.Atlas.Polity`, active over `[from_year, to_year]` (signed
  astronomical years, `.claude/rules/geo-temporal.md`).

  `geom` is the validated reference geometry (`ST_MakeValid` +
  `ST_CollectionExtract(..., 3)` + `ST_Multi`, ADR 0007); `geom_medium` and
  `geom_low` are pre-simplified levels (`ST_SimplifyPreserveTopology`,
  revalidated) filled by the same import pipeline so the web edge (#025)
  never simplifies at request time. All three, when present, are
  `MultiPolygon` in SRID 4326.

  `precision` is a source-specific coarseness marker: `nil` for Cliopatria,
  historical-basemaps' `BORDERPRECISION` for #024.

  Internal to the Atlas context: only `Amanogawa.Atlas` is called from
  other contexts or from the web layer. The geometry validation/
  simplification pipeline itself runs in SQL (`Amanogawa.Atlas.
  BorderQueries`), not through this changeset: rows built by ingestion
  already carry validated geometries by the time they reach here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @schema_prefix "atlas"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "borders" do
    field :geom, Geo.PostGIS.Geometry
    field :geom_medium, Geo.PostGIS.Geometry
    field :geom_low, Geo.PostGIS.Geometry

    field :from_year, :integer
    field :to_year, :integer
    field :source, :string
    field :precision, :integer

    # Area of geom_medium in square kilometers, precomputed at import time
    # (`Amanogawa.Atlas.BorderQueries.insert_batch/3`) so the read side
    # (`list_active_borders/1`) never recomputes ST_Area per request.
    field :area_km2, :float

    belongs_to :polity, Amanogawa.Atlas.Polity, type: Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @castable_fields [
    :polity_id,
    :geom,
    :geom_medium,
    :geom_low,
    :from_year,
    :to_year,
    :source,
    :precision,
    :area_km2
  ]

  @doc """
  Builds and validates a changeset: `polity_id`, `geom`, `from_year`,
  `to_year` and `source` are required; `from_year <= to_year` is enforced
  by a changeset validation backed by the migration's own database check
  constraint (`from_year_before_or_equal_to_year`, defense in depth). Every
  present geometry (`geom`, `geom_medium`, `geom_low`) must be a
  `MultiPolygon` in SRID 4326.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(border, attrs) do
    border
    |> cast(attrs, @castable_fields)
    |> validate_required([:polity_id, :geom, :from_year, :to_year, :source])
    |> foreign_key_constraint(:polity_id)
    |> validate_year_order()
    |> check_constraint(:to_year, name: :from_year_before_or_equal_to_year)
    |> validate_geom_srid(:geom)
    |> validate_geom_srid(:geom_medium)
    |> validate_geom_srid(:geom_low)
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

  # A `nil` field is never an error here (`geom_medium`/`geom_low` are
  # optional at the changeset level, even though the import pipeline always
  # fills them): only a *present but wrong* geometry is rejected.
  defp validate_geom_srid(changeset, field) do
    case get_field(changeset, field) do
      nil -> changeset
      %Geo.MultiPolygon{srid: 4326} -> changeset
      %Geo.MultiPolygon{} -> add_error(changeset, field, "must have SRID 4326")
      _ -> add_error(changeset, field, "must be a MultiPolygon geometry")
    end
  end
end
