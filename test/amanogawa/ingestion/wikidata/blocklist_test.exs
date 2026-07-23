defmodule Amanogawa.Ingestion.Wikidata.BlocklistTest do
  use ExUnit.Case, async: true

  doctest Amanogawa.Ingestion.Wikidata.Blocklist

  alias Amanogawa.Ingestion.Wikidata.Blocklist

  describe "qids/0" do
    test "is not empty" do
      assert Blocklist.qids() != []
    end

    test "every entry matches the Wikidata QID format" do
      assert Enum.all?(Blocklist.qids(), &Regex.match?(~r/^Q\d+$/, &1))
    end

    test "has no duplicate" do
      qids = Blocklist.qids()
      assert Enum.uniq(qids) == qids
    end

    test "includes the seed classes named by the F02 overview and the wikidata-query skill" do
      qids = Blocklist.qids()
      assert "Q27020041" in qids
      assert "Q40231" in qids
    end
  end
end
