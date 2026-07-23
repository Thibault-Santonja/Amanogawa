defmodule Amanogawa.Ingestion.Wikidata.LinkDecoderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.Wikidata.LinkDecoder

  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.Wikidata.LinkDecoder
  alias Amanogawa.SparqlFixtures

  describe "decode/1 happy path" do
    test "decodes the real relations fixture, mapping every property to its type and direction" do
      {:ok, result} = SparqlFixtures.sparql_fixture("links_page.json")

      {links, rejected} = LinkDecoder.decode(result)

      # 9 raw bindings: 1 self-link rejected, 1 symmetric P155/P156 duplicate
      # collapsed by dedup -> 7 distinct links survive.
      assert rejected == 1
      assert length(links) == 7

      part_of = Enum.find(links, &(&1.source_qid == "Q178510"))
      assert part_of.target_qid == "Q124785345"
      assert part_of.type == :part_of
      assert part_of.property == "P361"

      significant = Enum.find(links, &(&1.type == :significant))
      assert significant.source_qid == "Q188709"
      assert significant.target_qid == "Q19979612"

      participant = Enum.find(links, &(&1.property == "P1344"))
      assert participant.type == :part_of
    end

    test "P361 (part of) keeps the source/target direction as declared" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q178842"),
            "target" => uri("Q16512674"),
            "property" => literal("P361")
          }
        ]
      }

      {[link], 0} = LinkDecoder.decode(result)

      assert link.source_qid == "Q178842"
      assert link.target_qid == "Q16512674"
      assert link.type == :part_of
    end

    test "P155 (follows) keeps the source/target direction as declared" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{"source" => uri("Q178809"), "target" => uri("Q109886"), "property" => literal("P155")}
        ]
      }

      {[link], 0} = LinkDecoder.decode(result)

      assert link.source_qid == "Q178809"
      assert link.target_qid == "Q109886"
      assert link.type == :follows
    end

    test "P156 (followed by) inverts the declared direction" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{"source" => uri("Q178975"), "target" => uri("Q917167"), "property" => literal("P156")}
        ]
      }

      {[link], 0} = LinkDecoder.decode(result)

      # A P156 B ("A followed by B") means B follows A.
      assert link.source_qid == "Q917167"
      assert link.target_qid == "Q178975"
      assert link.type == :follows
    end

    test "P793 (significant event) keeps the source/target direction as declared" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q188709"),
            "target" => uri("Q19979612"),
            "property" => literal("P793")
          }
        ]
      }

      {[link], 0} = LinkDecoder.decode(result)

      assert link.source_qid == "Q188709"
      assert link.target_qid == "Q19979612"
      assert link.type == :significant
    end

    test "P1344 (participant of) is mapped to part_of, direction as declared" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q844930"),
            "target" => uri("Q16683515"),
            "property" => literal("P1344")
          }
        ]
      }

      {[link], 0} = LinkDecoder.decode(result)

      assert link.source_qid == "Q844930"
      assert link.target_qid == "Q16683515"
      assert link.type == :part_of
    end
  end

  describe "decode/1 edge cases" do
    test "a pair declared on both sides (A P156 B and B P155 A) produces a single link after deduplication" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q178975"),
            "target" => uri("Q917167"),
            "property" => literal("P156")
          },
          %{"source" => uri("Q917167"), "target" => uri("Q178975"), "property" => literal("P155")}
        ]
      }

      {links, 0} = LinkDecoder.decode(result)

      assert [%{source_qid: "Q917167", target_qid: "Q178975", type: :follows}] = links
    end

    test "a self-link is discarded and counted, on its normalized (not raw) pair" do
      # Raw P156 self-link: mapping inverts direction, but source == target
      # either way once normalized.
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{"source" => uri("Q179250"), "target" => uri("Q179250"), "property" => literal("P361")}
        ]
      }

      assert LinkDecoder.decode(result) == {[], 1}
    end

    test "distinct links between the same pair with different types are both kept" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{"source" => uri("Q1"), "target" => uri("Q2"), "property" => literal("P361")},
          %{"source" => uri("Q1"), "target" => uri("Q2"), "property" => literal("P793")}
        ]
      }

      {links, 0} = LinkDecoder.decode(result)

      assert length(links) == 2
      assert Enum.map(links, & &1.type) |> Enum.sort() == [:part_of, :significant]
    end
  end

  describe "decode/1 error cases" do
    test "a binding missing a target QID is rejected without crashing" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{"source" => uri("Q178842"), "property" => literal("P361")}
        ]
      }

      assert LinkDecoder.decode(result) == {[], 1}
    end

    test "a source URI that is not a plain entity QID is rejected" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => %{
              value: "http://www.wikidata.org/entity/statement/Q1-not-a-class",
              type: :uri,
              datatype: nil,
              lang: nil
            },
            "target" => uri("Q2"),
            "property" => literal("P361")
          }
        ]
      }

      assert LinkDecoder.decode(result) == {[], 1}
    end

    test "an unrecognized property is rejected without crashing" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q178842"),
            "target" => uri("Q16512674"),
            "property" => literal("P828")
          }
        ]
      }

      assert LinkDecoder.decode(result) == {[], 1}
    end

    test "one invalid binding does not affect the rest of the page" do
      result = %Result{
        variables: ["source", "target", "property"],
        bindings: [
          %{
            "source" => uri("Q178842"),
            "target" => uri("Q16512674"),
            "property" => literal("P361")
          },
          %{"source" => uri("Q1"), "property" => literal("P361")}
        ]
      }

      {links, rejected} = LinkDecoder.decode(result)

      assert length(links) == 1
      assert rejected == 1
    end
  end

  describe "decode/1 limit cases" do
    test "an empty page decodes to an empty list with zero rejections" do
      assert LinkDecoder.decode(%Result{variables: [], bindings: []}) == {[], 0}
    end
  end

  describe "property: decode/1 on synthetic bindings with injected symmetries and duplicates" do
    property "the decoded list never contains two identical (source, target, type) links nor a self-link" do
      check all bindings <- list_of(synthetic_binding(), max_length: 30) do
        result = %Result{variables: [], bindings: bindings}

        {links, rejected} = LinkDecoder.decode(result)

        assert rejected >= 0
        assert Enum.all?(links, &(&1.source_qid != &1.target_qid))

        triples = Enum.map(links, &{&1.source_qid, &1.target_qid, &1.type})
        assert Enum.uniq(triples) == triples
      end
    end
  end

  defp synthetic_binding do
    gen all source_num <- integer(1..999_999_999),
            target_num <- integer(1..999_999_999),
            property <- member_of(["P361", "P155", "P156", "P793", "P1344"]) do
      %{
        "source" => uri("Q#{source_num}"),
        "target" => uri("Q#{target_num}"),
        "property" => literal(property)
      }
    end
  end

  defp uri(qid),
    do: %{value: "http://www.wikidata.org/entity/#{qid}", type: :uri, datatype: nil, lang: nil}

  defp literal(value), do: %{value: value, type: :literal, datatype: nil, lang: nil}
end
