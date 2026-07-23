defmodule Amanogawa.Repo.Migrations.CreateAtlasPolitiesAndBorders do
  use Ecto.Migration

  @moduledoc """
  Creates `atlas.polities` and `atlas.borders`, the read model for F05
  (historical borders): dated polygons of political entities, imported from
  Cliopatria (issue #023) and historical-basemaps (issue #024).

  A polity has no geometry of its own: it is a named entity (a kingdom, an
  empire, ...) identified by `(name, source)`, existing over `from_year`/
  `to_year` (nullable: the source dataset does not always carry an overall
  existence span for the entity, only per-polygon dates). Its territory at
  any given year is the union of its `borders` rows active at that year.

  `atlas.borders` carries the actual dated polygon: `geom` is the validated
  reference geometry (SRID 4326, MultiPolygon); `geom_medium`/`geom_low` are
  pre-simplified levels (`ST_SimplifyPreserveTopology`, ADR 0007) so the web
  edge (#025) never simplifies at request time. `from_year`/`to_year` are
  signed astronomical years (`.claude/rules/geo-temporal.md`: never a
  PostgreSQL `date`), required (unlike the polity's own span) since "borders
  active at year A" is the query this table exists to serve.

  Idempotent re-import (`Amanogawa.Atlas.replace_borders/2`) purges and
  reinserts by `source`, so no soft-delete or versioning column is needed
  here.
  """

  def change do
    create table(:polities, primary_key: false, prefix: "atlas") do
      add :id, :binary_id, primary_key: true

      add :name, :text, null: false
      add :from_year, :integer
      add :to_year, :integer
      add :source, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polities, [:name, :source], prefix: "atlas")

    create table(:borders, primary_key: false, prefix: "atlas") do
      add :id, :binary_id, primary_key: true

      add :polity_id,
          references(:polities,
            type: :binary_id,
            prefix: "atlas",
            on_delete: :delete_all
          ),
          null: false

      add :geom, :"geometry(MultiPolygon,4326)", null: false
      add :geom_medium, :"geometry(MultiPolygon,4326)"
      add :geom_low, :"geometry(MultiPolygon,4326)"

      add :from_year, :integer, null: false
      add :to_year, :integer, null: false
      add :source, :text, null: false

      # Source-specific confidence/coarseness marker: nil for Cliopatria,
      # historical-basemaps' BORDERPRECISION for #024 (a rough zone of
      # influence, not a claimed exact border).
      add :precision, :integer

      timestamps(type: :utc_datetime)
    end

    create constraint(:borders, :from_year_before_or_equal_to_year,
             check: "from_year <= to_year",
             prefix: "atlas"
           )

    create index(:borders, [:geom], using: :gist, prefix: "atlas")
    create index(:borders, [:geom_medium], using: :gist, prefix: "atlas")
    create index(:borders, [:geom_low], using: :gist, prefix: "atlas")
    create index(:borders, [:from_year, :to_year], prefix: "atlas")
    create index(:borders, [:polity_id], prefix: "atlas")
    create index(:borders, [:source], prefix: "atlas")
  end
end
