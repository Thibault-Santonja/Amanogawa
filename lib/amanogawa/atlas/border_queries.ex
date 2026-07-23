defmodule Amanogawa.Atlas.BorderQueries do
  @moduledoc """
  The PostGIS geometry pipeline for `atlas.borders` (ADR 0007, issue #023):
  every fragment that validates, repairs, simplifies, or reads back a
  border geometry lives here (`.claude/rules/architecture.md`: "Raw SQL for
  geo -> use PostGIS functions via fragments in one query module"), so no
  other module builds one of these expressions. `list_active_borders/1` and
  `last_import_at/0` (issue #025) are the read side of that same pipeline,
  serving `GET /api/borders`.

  ## Pipeline

  For each input row (a GeoJSON geometry plus its `atlas.borders` scalar
  attributes):

    1. `ST_SetSRID(ST_GeomFromGeoJSON(raw_geometry), 4326)` parses the raw
       GeoJSON geometry (a `Polygon` or `MultiPolygon`) and stamps it with
       SRID 4326 (`ST_GeomFromGeoJSON` alone returns SRID 0: GeoJSON is
       implicitly CRS84/WGS84, but PostGIS does not infer that on its own).
    2. `ST_MakeValid` repairs a self-intersecting or otherwise invalid ring
       (common in hand-digitized historical sources); `ST_CollectionExtract(
       ..., 3)` keeps only the polygonal parts of whatever `ST_MakeValid`
       produced (it can return a `GeometryCollection` mixing points, lines
       and polygons for a badly broken input); `ST_Multi` normalizes a
       simple `Polygon` into a one-part `MultiPolygon`, matching the
       column's declared type either way.
    3. `geom_medium`/`geom_low` are `ST_SimplifyPreserveTopology` of the
       already-valid `geom` (never of the raw input) at `medium_tolerance`/
       `low_tolerance` degrees, revalidated through the same MakeValid +
       CollectionExtract + Multi chain: `ST_SimplifyPreserveTopology` can
       itself produce an invalid result on pathological input, so the
       simplified levels are never assumed valid by construction.
    4. A geometry that is still empty after step 2 (every ring degenerated
       away) is excluded from insertion and counted, never raised: a single
       malformed feature in a 300MB import must not abort the whole run.

  `insert_batch/3` runs steps 1-4 for a whole batch in one round trip (a
  single SQL statement, `unnest` over parallel arrays, PostgreSQL
  data-modifying CTEs for the insert itself), so memory stays bounded to one
  batch regardless of how large the source file is
  (`Amanogawa.Ingestion.Borders.GeojsonStream` is what keeps the *reading*
  side bounded; this module is what keeps the *writing* side bounded).

  Internal to the Atlas context: called only by `Amanogawa.Atlas.
  replace_borders/3`.
  """

  import Ecto.Query

  alias Amanogawa.Atlas.Border
  alias Amanogawa.Atlas.Polity
  alias Amanogawa.Repo

  # Starting point suggested by issue #023, to be recalibrated once real
  # Cliopatria payload sizes are measured end to end (finalized in #025's
  # gzip budget).
  @default_medium_tolerance 0.01
  @default_low_tolerance 0.05

  @type raw_row :: %{
          optional(:id) => Ecto.UUID.t(),
          polity_id: Ecto.UUID.t(),
          geometry: map(),
          from_year: integer(),
          to_year: integer(),
          source: String.t(),
          precision: integer() | nil
        }

  @type batch_stats :: %{
          total: non_neg_integer(),
          repaired: non_neg_integer(),
          inserted: non_neg_integer(),
          rejected_empty: non_neg_integer()
        }

  @type active_row :: %{
          name: String.t(),
          source: String.t(),
          precision: integer() | nil,
          geometry: String.t(),
          area_km2: float()
        }

  @insert_sql """
  WITH input AS (
    SELECT *
    FROM unnest($1::uuid[], $2::uuid[], $3::text[], $4::int[], $5::int[], $6::text[], $7::int[])
      AS t(id, polity_id, raw_geometry, from_year, to_year, source, precision)
  ),
  computed AS (
    SELECT
      id, polity_id, from_year, to_year, source, precision,
      ST_IsValid(ST_SetSRID(ST_GeomFromGeoJSON(raw_geometry), 4326)) AS was_valid,
      ST_Multi(
        ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON(raw_geometry), 4326)), 3)
      ) AS geom
    FROM input
  ),
  leveled AS (
    SELECT
      id, polity_id, from_year, to_year, source, precision, geom,
      ST_Multi(
        ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, $8::float)), 3)
      ) AS geom_medium,
      ST_Multi(
        ST_CollectionExtract(ST_MakeValid(ST_SimplifyPreserveTopology(geom, $9::float)), 3)
      ) AS geom_low
    FROM computed
    WHERE NOT ST_IsEmpty(geom)
  ),
  measured AS (
    -- area_km2 is precomputed at import time over geom_medium (the level
    -- the web edge serves, so the area a client filters labels by matches
    -- what it renders) rather than per read request (F05 quality finding:
    -- ST_Area over a geography cast is too expensive to recompute on
    -- every GET /api/borders).
    SELECT *, ST_Area(geom_medium::geography) / 1000000.0 AS area_km2
    FROM leveled
  ),
  ins AS (
    INSERT INTO atlas.borders
      (id, polity_id, geom, geom_medium, geom_low, from_year, to_year, source, "precision",
       area_km2, inserted_at, updated_at)
    SELECT
      id, polity_id, geom, geom_medium, geom_low, from_year, to_year, source, precision,
      area_km2, $10::timestamp, $10::timestamp
    FROM measured
    RETURNING id
  )
  SELECT
    (SELECT count(*) FROM computed) AS total,
    (SELECT count(*) FROM computed WHERE NOT was_valid) AS repaired,
    (SELECT count(*) FROM ins) AS inserted
  """

  @doc "Deletes every `atlas.borders` row of `source`. Returns the deleted count."
  @spec purge_source(String.t()) :: non_neg_integer()
  def purge_source(source) do
    {count, _} = Border |> where([b], b.source == ^source) |> Repo.delete_all()
    count
  end

  @doc """
  Deletes every `atlas.polities` row of `source` no longer referenced by
  any border (F05 quality finding: a purge-then-reinsert that drops an
  entity would otherwise leave its polity row behind forever). Returns the
  deleted count. Called by `Amanogawa.Atlas.replace_borders/3` inside its
  transaction, after the new rows are in, so polities still referenced by
  the fresh import always survive.
  """
  @spec purge_orphan_polities(String.t()) :: non_neg_integer()
  def purge_orphan_polities(source) do
    still_referenced = from b in Border, where: b.polity_id == parent_as(:polity).id

    orphans =
      from p in Polity,
        as: :polity,
        where: p.source == ^source,
        where: not exists(still_referenced)

    {count, _} = Repo.delete_all(orphans)
    count
  end

  @doc """
  Counts pairs of borders of `source` on the same polity where one row's
  `to_year` equals another's `from_year` (see `Amanogawa.Atlas.
  count_boundary_year_overlaps/1` for the interval-convention rationale).
  Each ordered pair counts once.
  """
  @spec count_boundary_year_overlaps(String.t()) :: non_neg_integer()
  def count_boundary_year_overlaps(source) do
    Border
    |> join(:inner, [b1], b2 in Border,
      on: b1.polity_id == b2.polity_id and b1.to_year == b2.from_year and b1.id != b2.id
    )
    |> where([b1, b2], b1.source == ^source and b2.source == ^source)
    |> select([b1, b2], count())
    |> Repo.one()
  end

  @doc """
  Lists the polygons active at `year` (issue #025, `from_year <= year AND
  to_year >= year`, both bounds inclusive), joined to their polity's
  `name`, at the default web simplification level (`geom_medium`, #023: the
  web edge never simplifies at request time).

  `geometry` is already `ST_AsGeoJSON` text (ADR 0007: GeoJSON serialization
  happens here, in the query module, never in the controller or the
  client), capped at 5 decimal digits per coordinate (about 1 meter of
  precision at the equator: far beyond what a simplified historical
  border legitimately claims, and a substantial payload saving over the
  9-digit default); `area_km2` is the value precomputed at import time by
  `insert_batch/3` over the same simplified geometry (the area a client
  filters labels by matches what it actually renders), never recomputed
  per request.

  Ordered by polity name then border id, for a deterministic response
  (`Amanogawa.Atlas.list_borders_geojson/1`'s feature order is otherwise at
  the mercy of undefined row order across two structurally identical
  queries, which would make caching and tests flaky).
  """
  @spec list_active_borders(integer()) :: [active_row()]
  def list_active_borders(year) do
    Border
    |> join(:inner, [b], p in Polity, on: b.polity_id == p.id)
    |> where([b], b.from_year <= ^year and b.to_year >= ^year)
    |> order_by([b, p], asc: p.name, asc: b.id)
    |> select([b, p], %{
      name: p.name,
      source: b.source,
      precision: b.precision,
      geometry: fragment("ST_AsGeoJSON(?, 5)", b.geom_medium),
      area_km2: b.area_km2
    })
    |> Repo.all()
  end

  @doc """
  The timestamp of the most recent `atlas.borders` write (`max(updated_at)`),
  or `nil` when the table is empty. Backs the borders endpoint's ETag
  (issue #025, `AmanogawaWeb.Controllers.Api.BorderController`): a fresh
  import (`Amanogawa.Atlas.replace_borders/3`) always advances this value,
  which is what invalidates every previously cached response, without a
  dedicated import-metadata table.
  """
  @spec last_import_at() :: DateTime.t() | nil
  def last_import_at do
    Repo.one(from b in Border, select: max(b.updated_at))
  end

  @doc """
  Runs the geometry pipeline (see moduledoc) on `rows` and inserts every
  surviving one, in a single round trip. Returns counts for `total` (input
  rows), `repaired` (rows whose raw geometry was invalid before step 2),
  `inserted` and `rejected_empty` (`inserted = total - rejected_empty`).

  `rows` missing `:id` get a fresh UUID v7, matching every other Atlas
  schema's id scheme.
  """
  @spec insert_batch([raw_row()], float(), float()) :: batch_stats()
  def insert_batch(
        rows,
        medium_tolerance \\ @default_medium_tolerance,
        low_tolerance \\ @default_low_tolerance
      )

  def insert_batch([], _medium_tolerance, _low_tolerance) do
    %{total: 0, repaired: 0, inserted: 0, rejected_empty: 0}
  end

  def insert_batch(rows, medium_tolerance, low_tolerance) do
    prepared = Enum.map(rows, &prepare_row/1)
    now = utc_now()

    params = [
      Enum.map(prepared, &Ecto.UUID.dump!(&1.id)),
      Enum.map(prepared, &Ecto.UUID.dump!(&1.polity_id)),
      Enum.map(prepared, &Jason.encode!(&1.geometry)),
      Enum.map(prepared, & &1.from_year),
      Enum.map(prepared, & &1.to_year),
      Enum.map(prepared, & &1.source),
      Enum.map(prepared, & &1.precision),
      medium_tolerance,
      low_tolerance,
      now
    ]

    %Postgrex.Result{rows: [[total, repaired, inserted]]} = Repo.query!(@insert_sql, params)

    %{
      total: total,
      repaired: repaired,
      inserted: inserted,
      rejected_empty: total - inserted
    }
  end

  defp prepare_row(row) do
    row
    |> Map.new()
    |> Map.put_new_lazy(:id, fn -> Ecto.UUID.generate(version: 7) end)
  end

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
