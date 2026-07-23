defmodule Amanogawa.Atlas.BorderQueriesTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas.Border
  alias Amanogawa.Atlas.BorderQueries

  @valid_square %{
    "type" => "Polygon",
    "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]
  }

  # Self-intersecting ("bowtie") ring: invalid, but ST_MakeValid repairs it
  # into a valid (Multi)Polygon rather than an empty geometry.
  @bowtie %{
    "type" => "Polygon",
    "coordinates" => [[[0.0, 0.0], [1.0, 1.0], [1.0, 0.0], [0.0, 1.0], [0.0, 0.0]]]
  }

  # A degenerate ring (three collinear points, zero area): still invalid
  # after ST_MakeValid, and empty, meant to be rejected and counted.
  @degenerate %{
    "type" => "Polygon",
    "coordinates" => [[[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]]
  }

  defp row(polity_id, geometry, overrides \\ %{}) do
    Map.merge(
      %{
        polity_id: polity_id,
        geometry: geometry,
        from_year: -100,
        to_year: 100,
        source: "cliopatria",
        precision: nil
      },
      overrides
    )
  end

  describe "insert_batch/3: happy path" do
    test "a valid Polygon is inserted as a valid MultiPolygon in SRID 4326" do
      polity = polity_fixture()
      stats = BorderQueries.insert_batch([row(polity.id, @valid_square)])

      assert stats == %{total: 1, repaired: 0, inserted: 1, rejected_empty: 0}

      [border] = Repo.all(Border)
      assert %Geo.MultiPolygon{srid: 4326} = border.geom
      assert %Geo.MultiPolygon{srid: 4326} = border.geom_medium
      assert %Geo.MultiPolygon{srid: 4326} = border.geom_low
    end

    test "a MultiPolygon geometry is accepted as-is" do
      polity = polity_fixture()
      multi = %{"type" => "MultiPolygon", "coordinates" => [@valid_square["coordinates"]]}

      stats = BorderQueries.insert_batch([row(polity.id, multi)])
      assert stats.inserted == 1
    end

    test "geom_medium and geom_low are valid (ST_IsValid) after simplification" do
      polity = polity_fixture()
      BorderQueries.insert_batch([row(polity.id, @valid_square)])

      [border] = Repo.all(Border)

      assert valid_geometry?(border.geom)
      assert valid_geometry?(border.geom_medium)
      assert valid_geometry?(border.geom_low)
    end

    test "precision is stored when given" do
      polity = polity_fixture()
      BorderQueries.insert_batch([row(polity.id, @valid_square, %{precision: 2})])

      assert [%Border{precision: 2}] = Repo.all(Border)
    end
  end

  describe "insert_batch/3: edge case" do
    test "an invalid (self-intersecting) geometry is repaired and inserted valid" do
      polity = polity_fixture()
      stats = BorderQueries.insert_batch([row(polity.id, @bowtie)])

      assert stats == %{total: 1, repaired: 1, inserted: 1, rejected_empty: 0}
      assert [border] = Repo.all(Border)
      assert valid_geometry?(border.geom)
    end

    test "an empty batch returns zeroed stats without querying the database" do
      assert BorderQueries.insert_batch([]) == %{
               total: 0,
               repaired: 0,
               inserted: 0,
               rejected_empty: 0
             }
    end

    test "custom tolerances are honored" do
      polity = polity_fixture()
      stats = BorderQueries.insert_batch([row(polity.id, @valid_square)], 0.001, 0.5)
      assert stats.inserted == 1
    end
  end

  describe "insert_batch/3: error/limit case" do
    test "a geometry still empty after repair is rejected and counted, not raised" do
      polity = polity_fixture()
      stats = BorderQueries.insert_batch([row(polity.id, @degenerate)])

      assert stats == %{total: 1, repaired: 1, inserted: 0, rejected_empty: 1}
      assert Repo.aggregate(Border, :count) == 0
    end

    test "a mixed batch inserts the survivors and counts the rest correctly" do
      polity = polity_fixture()

      rows = [
        row(polity.id, @valid_square),
        row(polity.id, @bowtie),
        row(polity.id, @degenerate)
      ]

      stats = BorderQueries.insert_batch(rows)
      assert stats == %{total: 3, repaired: 2, inserted: 2, rejected_empty: 1}
      assert Repo.aggregate(Border, :count) == 2
    end
  end

  describe "purge_source/1" do
    test "deletes only the rows of the given source, returns the deleted count" do
      polity = polity_fixture()
      border_fixture(polity_id: polity.id, source: "cliopatria")
      border_fixture(polity_id: polity.id, source: "cliopatria")
      other_polity = polity_fixture(source: "historical_basemaps")
      border_fixture(polity_id: other_polity.id, source: "historical_basemaps")

      assert BorderQueries.purge_source("cliopatria") == 2
      assert Repo.aggregate(Border, :count) == 1
    end

    test "purging an unknown source deletes nothing" do
      assert BorderQueries.purge_source("nonexistent") == 0
    end
  end

  describe "list_active_borders/1" do
    test "returns only polygons active at the given year (from_year and to_year both inclusive)" do
      polity = polity_fixture(name: "Roman Empire")
      border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      assert [row] = BorderQueries.list_active_borders(-100)
      assert row.name == "Roman Empire"

      assert [row] = BorderQueries.list_active_borders(100)
      assert row.name == "Roman Empire"

      assert [row] = BorderQueries.list_active_borders(0)
      assert row.name == "Roman Empire"
    end

    test "excludes a polygon the year before from_year or the year after to_year" do
      polity = polity_fixture()
      border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      assert BorderQueries.list_active_borders(-101) == []
      assert BorderQueries.list_active_borders(101) == []
    end

    test "a year with no matching border returns an empty list" do
      assert BorderQueries.list_active_borders(50_000) == []
    end

    test "each row carries name, source, precision, GeoJSON geometry text and area_km2" do
      polity = polity_fixture(name: "Roman Empire", source: "cliopatria")
      border_fixture(polity_id: polity.id, source: "cliopatria", precision: 2)

      assert [row] = BorderQueries.list_active_borders(0)
      assert row.name == "Roman Empire"
      assert row.source == "cliopatria"
      assert row.precision == 2
      assert %{"type" => "MultiPolygon"} = Jason.decode!(row.geometry)
      assert is_float(row.area_km2)
      assert row.area_km2 > 0
    end

    test "results are ordered by polity name, deterministically" do
      polity_b = polity_fixture(name: "B Empire")
      polity_a = polity_fixture(name: "A Empire")
      border_fixture(polity_id: polity_b.id)
      border_fixture(polity_id: polity_a.id)

      assert [%{name: "A Empire"}, %{name: "B Empire"}] = BorderQueries.list_active_borders(0)
    end
  end

  describe "last_import_at/1" do
    test "returns nil when atlas.borders is empty" do
      assert BorderQueries.last_import_at() == nil
    end

    test "returns the most recent updated_at across every border" do
      polity = polity_fixture()
      older = border_fixture(polity_id: polity.id)

      older
      |> Ecto.Changeset.change(updated_at: ~U[2020-01-01 00:00:00Z])
      |> Repo.update!()

      newer = border_fixture(polity_id: polity.id)

      newer
      |> Ecto.Changeset.change(updated_at: ~U[2025-06-01 00:00:00Z])
      |> Repo.update!()

      assert BorderQueries.last_import_at() == ~U[2025-06-01 00:00:00Z]
    end
  end

  defp valid_geometry?(geom) do
    %{rows: [[valid]]} = Repo.query!("SELECT ST_IsValid($1)", [geom])
    valid
  end
end
