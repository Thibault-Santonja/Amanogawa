defmodule Amanogawa.Ingestion.Cliopatria.ImporterTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.Cliopatria.Importer

  @fixture Path.join([
             __DIR__,
             "..",
             "..",
             "..",
             "support",
             "fixtures",
             "cliopatria",
             "sample.geojson"
           ])

  test "source/0 is the atlas.polities/atlas.borders source tag" do
    assert Importer.source() == "cliopatria"
  end

  describe "import/1: happy path" do
    test "imports the sample fixture and tags every row with source \"cliopatria\"" do
      assert {:ok, summary} = Importer.import(@fixture)
      assert summary.inserted == 3

      assert Atlas.count_borders() == 3
    end
  end

  describe "import/1: idempotence" do
    test "re-running the import against the same file yields the same final counts" do
      {:ok, _first} = Importer.import(@fixture)
      first_count = Atlas.count_borders()

      {:ok, second} = Importer.import(@fixture)

      assert second.purged == first_count
      assert Atlas.count_borders() == first_count
    end
  end

  describe "import/1: error case" do
    test "a nonexistent path raises rather than silently importing nothing" do
      assert_raise File.Error, fn -> Importer.import("/nonexistent/cliopatria.geojson") end
    end
  end
end
