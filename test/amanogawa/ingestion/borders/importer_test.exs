defmodule Amanogawa.Ingestion.Borders.ImporterTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.Borders.Importer
  alias Amanogawa.Ingestion.Cliopatria.Parser

  @cliopatria_fixture Path.join([
                        __DIR__,
                        "..",
                        "..",
                        "..",
                        "support",
                        "fixtures",
                        "cliopatria",
                        "sample.geojson"
                      ])

  # A minimal always-ok parser for tests that only care about the streaming/
  # polity-resolution machinery, not any real source's parsing rules.
  defp always_ok(feature) do
    name = get_in(feature, ["properties", "Name"]) || get_in(feature, ["properties", "NAME"])

    {:ok,
     %{name: name, geometry: feature["geometry"], from_year: -100, to_year: 100, precision: nil}}
  end

  describe "import/3: happy path" do
    test "streams the real-shaped Cliopatria fixture into atlas.polities and atlas.borders" do
      cliopatria_parser = &Parser.parse_feature/1

      assert {:ok, summary} =
               Importer.import(@cliopatria_fixture, "cliopatria", cliopatria_parser)

      # 7 features total: 2 Roman Empire (POLITY, valid), 1 Byzantine
      # Empire (POLITY, valid MultiPolygon), 1 RELATION (skipped), 1
      # missing Name (invalid), 1 from_year > to_year (invalid), 1
      # degenerate geometry (parses fine, rejected downstream as empty).
      assert summary.total == 4
      assert summary.skipped == 1
      assert summary.invalid_features == 2
      assert summary.inserted == 3
      assert summary.rejected_empty == 1

      assert Atlas.count_borders() == 3
      # Roman Empire (x2 time slices, one polity row) and Byzantine
      # Empire. Degenerate Sliver parses fine but its only border row is
      # rejected as empty, so its polity ends the transaction orphaned
      # and is purged with it.
      assert summary.purged_polities == 1
      assert Atlas.count_polities() == 2
    end
  end

  describe "import/3: edge case" do
    test "a name seen twice resolves to the same polity_id (memoized, no duplicate upsert)" do
      path = write_tmp!(~s({"features":[
        {"type":"Feature","properties":{"Name":"Rome"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[1,0],[0,0]]]}},
        {"type":"Feature","properties":{"Name":"Rome"},"geometry":{"type":"Polygon","coordinates":[[[2,2],[2,3],[3,3],[3,2],[2,2]]]}}
      ]}))

      on_exit_delete(path)

      assert {:ok, summary} = Importer.import(path, "test_source", &always_ok/1)
      assert summary.inserted == 2
      assert Atlas.count_polities() == 1
      assert Atlas.count_borders() == 2
    end

    test "an empty features array produces an all-zero summary" do
      path = write_tmp!(~s({"features":[]}))
      on_exit_delete(path)

      assert {:ok, summary} = Importer.import(path, "test_source", &always_ok/1)

      assert summary == %{
               purged: 0,
               purged_polities: 0,
               total: 0,
               repaired: 0,
               inserted: 0,
               rejected_empty: 0,
               skipped: 0,
               invalid_features: 0
             }
    end
  end

  describe "import/3: error case" do
    test "malformed JSON inside one feature is counted as invalid_features, others still import" do
      path = write_tmp!(~s({"features":[
        {"type":"Feature","properties":{"Name":"Rome"},"geometry":{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[1,0],[0,0]]]}},
        {"type":"Feature","properties":{"Name": invalid_token}}
      ]}))

      on_exit_delete(path)

      assert {:ok, summary} = Importer.import(path, "test_source", &always_ok/1)
      assert summary.inserted == 1
      assert summary.invalid_features == 1
    end

    test "anti-wipe guard: a wrong file (100% invalid features) leaves previous data intact" do
      good_path = write_tmp!(~s({"features":[
        {"type":"Feature","properties":{"Name":"Rome","FromYear":-100,"ToYear":100},"geometry":{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[1,0],[0,0]]]}}
      ]}))

      # Every feature fails the parser: without the guard, the purge of
      # the previous rows would commit alongside zero insertions.
      bad_path = write_tmp!(~s({"features":[
        {"type":"Feature","properties":{"Name":"Rome"},"geometry":null},
        {"type":"Feature","properties":{},"geometry":null}
      ]}))

      on_exit_delete(good_path)
      on_exit_delete(bad_path)

      assert {:ok, %{inserted: 1}} =
               Importer.import(good_path, "cliopatria", &Parser.parse_feature/1)

      assert {:error, {:would_wipe_source, "cliopatria", 1}} =
               Importer.import(bad_path, "cliopatria", &Parser.parse_feature/1)

      # The rollback preserved the previous import in full.
      assert Atlas.count_borders() == 1
      assert Atlas.count_polities() == 1
    end

    test "anti-wipe guard: force: true deliberately empties the source on the same wrong file" do
      good_path = write_tmp!(~s({"features":[
        {"type":"Feature","properties":{"Name":"Rome","FromYear":-100,"ToYear":100},"geometry":{"type":"Polygon","coordinates":[[[0,0],[0,1],[1,1],[1,0],[0,0]]]}}
      ]}))

      bad_path = write_tmp!(~s({"features":[{"type":"Feature","properties":{},"geometry":null}]}))

      on_exit_delete(good_path)
      on_exit_delete(bad_path)

      assert {:ok, _} = Importer.import(good_path, "cliopatria", &Parser.parse_feature/1)

      assert {:ok, summary} =
               Importer.import(bad_path, "cliopatria", &Parser.parse_feature/1, force: true)

      assert summary.purged == 1
      assert summary.inserted == 0
      assert Atlas.count_borders() == 0
    end
  end

  defp write_tmp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "borders_importer_test_#{System.unique_integer([:positive])}.geojson"
      )

    File.write!(path, content)
    path
  end

  defp on_exit_delete(path), do: ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
end
