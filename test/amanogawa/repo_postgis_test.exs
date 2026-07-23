defmodule Amanogawa.RepoPostgisTest do
  use Amanogawa.DataCase, async: true

  describe "PostGIS foundations" do
    test "the postgis extension is active in the test database" do
      %{rows: [[version]]} = Repo.query!("SELECT postgis_version()")

      assert is_binary(version)
      assert version =~ ~r/\d+\.\d+/
    end

    test "geometry results are decoded as Geo structs with SRID 4326" do
      %{rows: [[point]]} = Repo.query!("SELECT ST_SetSRID(ST_MakePoint(2.35, 48.85), 4326)")

      assert %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326} = point
    end

    test "the atlas and ingestion schemas exist" do
      %{rows: rows} =
        Repo.query!(
          "SELECT schema_name FROM information_schema.schemata WHERE schema_name = ANY($1)",
          [["atlas", "ingestion"]]
        )

      schemas = List.flatten(rows)

      assert "atlas" in schemas
      assert "ingestion" in schemas
    end
  end
end
