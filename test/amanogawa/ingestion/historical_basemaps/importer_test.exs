defmodule Amanogawa.Ingestion.HistoricalBasemaps.ImporterTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Border
  alias Amanogawa.Ingestion.HistoricalBasemaps.Importer

  @fixture_dir Path.join([
                 __DIR__,
                 "..",
                 "..",
                 "..",
                 "support",
                 "fixtures",
                 "historical_basemaps"
               ])

  test "source/0 is the atlas.polities/atlas.borders source tag" do
    assert Importer.source() == "historical_basemaps"
  end

  describe "import/1: happy path" do
    test "imports every recognized, in-range tranche of the fixture directory" do
      assert {:ok, summary} = Importer.import(@fixture_dir)

      # world_bc10000.geojson: Natufian culture (valid), one unnamed
      # feature (skipped). world_bc4000.geojson: Dapenkeng culture
      # (valid), Bowtie Culture (self-intersecting, repaired).
      # world_bc3000.geojson is excluded by the -3400 junction.
      assert summary.total == 3
      assert summary.skipped == 1
      assert summary.invalid_features == 0
      assert summary.repaired == 1
      assert summary.inserted == 3
      assert summary.rejected_empty == 0

      assert summary.tranches_imported == [-10_000, -4_000]
      assert summary.tranches_excluded == [-3_000]
      assert summary.unrecognized_files == ["unexpected_name.geojson"]

      assert Atlas.count_borders() == 3
      assert Atlas.count_polities() == 3
    end

    test "each tranche's rows carry its own from_year/to_year interval" do
      {:ok, _summary} = Importer.import(@fixture_dir)

      borders = Border |> Amanogawa.Repo.all() |> Enum.sort_by(& &1.from_year)

      assert Enum.map(borders, &{&1.from_year, &1.to_year}) == [
               {-10_000, -4_001},
               {-4_000, -3_401},
               {-4_000, -3_401}
             ]
    end

    test "BORDERPRECISION is stored as precision" do
      {:ok, _summary} = Importer.import(@fixture_dir)

      precisions = Border |> Amanogawa.Repo.all() |> Enum.map(& &1.precision) |> Enum.sort()
      assert precisions == [1, 1, 2]
    end
  end

  describe "import/1: idempotence" do
    test "re-running the import never touches Cliopatria's own rows" do
      polity = polity_fixture(source: "cliopatria")
      border_fixture(polity_id: polity.id, source: "cliopatria", from_year: -3400, to_year: 2024)

      {:ok, _summary} = Importer.import(@fixture_dir)

      cliopatria_borders =
        Border |> Amanogawa.Repo.all() |> Enum.filter(&(&1.source == "cliopatria"))

      assert length(cliopatria_borders) == 1

      {:ok, _summary} = Importer.import(@fixture_dir)

      cliopatria_borders =
        Border |> Amanogawa.Repo.all() |> Enum.filter(&(&1.source == "cliopatria"))

      assert length(cliopatria_borders) == 1
    end

    test "no imported row ever has from_year >= -3400" do
      {:ok, _summary} = Importer.import(@fixture_dir)

      assert Border
             |> Amanogawa.Repo.all()
             |> Enum.filter(&(&1.source == "historical_basemaps"))
             |> Enum.all?(&(&1.from_year < -3_400))
    end
  end

  describe "import/1: error case" do
    test "a nonexistent directory raises rather than silently importing nothing" do
      assert_raise File.Error, fn -> Importer.import("/nonexistent/historical_basemaps") end
    end
  end
end
