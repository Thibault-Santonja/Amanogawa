defmodule Amanogawa.Ingestion.Wikidata.TemplatesTest do
  use ExUnit.Case, async: true

  doctest Amanogawa.Ingestion.Wikidata.Templates

  alias Amanogawa.Ingestion.Wikidata.Templates

  describe "events_page/1" do
    test "renders the canonical extraction pattern: psv:, timePrecision, blocklist MINUS, GROUP BY" do
      query = Templates.events_page(%{lower: 0, upper: 1000, limit: 500, offset: 0})

      assert query =~ "psv:P585"
      assert query =~ "wikibase:timePrecision"
      assert query =~ "wikibase:timeCalendarModel"
      assert query =~ "MINUS { VALUES ?blocked"
      assert query =~ "GROUP BY ?e"
    end

    test "reads coordinates both directly (P625) and via place (P276 -> P625), with a bound requirement" do
      query = Templates.events_page(%{lower: 0, upper: 1000, limit: 500, offset: 0})

      assert query =~ "?e wdt:P625 ?coordDirectV"
      assert query =~ "?e wdt:P276/wdt:P625 ?coordPlaceV"
      assert query =~ "FILTER(BOUND(?coordDirectV) || BOUND(?coordPlaceV))"
    end

    test "falls back to P580 (start time) when P585 is absent, via MINUS rather than FILTER NOT EXISTS" do
      query = Templates.events_page(%{lower: 0, upper: 1000, limit: 500, offset: 0})

      assert query =~ "p:P580/psv:P580"
      assert query =~ "MINUS { ?e p:P585/psv:P585 ?anyBeginNode585 }"
      refute query =~ "FILTER NOT EXISTS"
    end

    test "renders the requested slice bounds and pagination" do
      query = Templates.events_page(%{lower: 178_000, upper: 179_300, limit: 250, offset: 500})

      assert query =~ "?qidNum >= 178000 && ?qidNum < 179300"
      assert query =~ "LIMIT 250"
      assert query =~ "OFFSET 500"
    end

    test "excludes the blocklist by QID" do
      query = Templates.events_page(%{lower: 0, upper: 1000, limit: 1, offset: 0})

      assert query =~ "wd:Q27020041"
      assert query =~ "wd:Q40231"
    end

    test "OFFSET 0 and LIMIT 1 render (limit case)" do
      query = Templates.events_page(%{lower: 0, upper: 1, limit: 1, offset: 0})

      assert query =~ "LIMIT 1"
      assert query =~ "OFFSET 0"
    end

    test "raises ArgumentError when a bound is not an integer" do
      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: "0", upper: 1000, limit: 500, offset: 0})
      end
    end

    test "raises ArgumentError when limit is zero or negative" do
      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: 0, upper: 1000, limit: 0, offset: 0})
      end

      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: 0, upper: 1000, limit: -1, offset: 0})
      end
    end

    test "raises ArgumentError when offset is negative" do
      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: 0, upper: 1000, limit: 500, offset: -1})
      end
    end

    test "raises ArgumentError when upper is not greater than lower" do
      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: 1000, upper: 1000, limit: 500, offset: 0})
      end

      assert_raise ArgumentError, fn ->
        Templates.events_page(%{lower: 1000, upper: 500, limit: 500, offset: 0})
      end
    end
  end

  describe "count_events/1" do
    test "renders a COUNT query sharing the same corpus definition" do
      query = Templates.count_events(%{lower: 0, upper: 1000})

      assert query =~ "COUNT(DISTINCT ?e)"
      assert query =~ "MINUS { VALUES ?blocked"
      assert query =~ "FILTER(BOUND(?coordDirectV) || BOUND(?coordPlaceV))"
      refute query =~ "GROUP BY"
      refute query =~ "LIMIT"
    end

    test "raises ArgumentError on the same invalid bounds as events_page/1" do
      assert_raise ArgumentError, fn -> Templates.count_events(%{lower: -1, upper: 1000}) end
      assert_raise ArgumentError, fn -> Templates.count_events(%{lower: 1000, upper: 0}) end
    end
  end

  describe "events_by_qids/1" do
    test "renders a VALUES clause with the given QIDs" do
      query = Templates.events_by_qids(["Q31900", "Q6539"])

      assert query =~ "VALUES ?e { wd:Q31900 wd:Q6539 }"
      assert query =~ "GROUP BY ?e"
    end

    test "raises ArgumentError on an empty list" do
      assert_raise ArgumentError, fn -> Templates.events_by_qids([]) end
    end

    test "raises ArgumentError on a malformed QID" do
      assert_raise ArgumentError, fn -> Templates.events_by_qids(["not-a-qid"]) end
      assert_raise ArgumentError, fn -> Templates.events_by_qids(["Q31900", "31900"]) end
      assert_raise ArgumentError, fn -> Templates.events_by_qids([123]) end
    end
  end
end
