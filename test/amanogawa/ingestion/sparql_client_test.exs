defmodule Amanogawa.Ingestion.SparqlClientTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.SparqlClient.Result

  alias Amanogawa.Ingestion.SparqlClient.Result

  describe "decode/1" do
    test "decodes a nominal result with variables and bindings, preserving datatype and lang" do
      json = ~s({
        "head": {"vars": ["s", "label"]},
        "results": {
          "bindings": [
            {
              "s": {"type": "uri", "value": "http://www.wikidata.org/entity/Q31900"},
              "label": {"type": "literal", "value": "bataille de Marathon", "xml:lang": "fr"}
            }
          ]
        }
      })

      assert {:ok, %Result{variables: ["s", "label"], bindings: [binding]}} = Result.decode(json)

      assert binding["s"] == %{
               value: "http://www.wikidata.org/entity/Q31900",
               type: :uri,
               datatype: nil,
               lang: nil
             }

      assert binding["label"] == %{
               value: "bataille de Marathon",
               type: :literal,
               datatype: nil,
               lang: "fr"
             }
    end

    test "decodes a literal with a datatype and no lang" do
      json = ~s({
        "head": {"vars": ["n"]},
        "results": {
          "bindings": [
            {"n": {"type": "literal", "value": "11", "datatype": "http://www.w3.org/2001/XMLSchema#int"}}
          ]
        }
      })

      assert {:ok, %Result{bindings: [%{"n" => value}]}} = Result.decode(json)
      assert value.datatype == "http://www.w3.org/2001/XMLSchema#int"
      assert value.lang == nil
    end

    test "accepts an already-decoded map (as Req may hand it when it recognizes the content-type)" do
      decoded = %{"head" => %{"vars" => ["s"]}, "results" => %{"bindings" => []}}

      assert {:ok, %Result{variables: ["s"], bindings: []}} = Result.decode(decoded)
    end

    test "empty result: zero bindings decodes to an empty list" do
      json = ~s({"head": {"vars": []}, "results": {"bindings": []}})

      assert {:ok, %Result{variables: [], bindings: []}} = Result.decode(json)
    end

    test "preserves non-ASCII literal values" do
      json = ~s({
        "head": {"vars": ["label"]},
        "results": {
          "bindings": [
            {"label": {"type": "literal", "value": "天の川 — événement", "xml:lang": "ja"}}
          ]
        }
      })

      assert {:ok, %Result{bindings: [%{"label" => value}]}} = Result.decode(json)
      assert value.value == "天の川 — événement"
    end

    test "invalid JSON returns an error tuple instead of raising" do
      assert {:error, %Jason.DecodeError{}} = Result.decode("not json at all {{{")
    end

    test "well-formed JSON with the wrong shape returns :invalid_result_shape" do
      assert {:error, :invalid_result_shape} = Result.decode(~s({"foo": "bar"}))
    end

    test "a binding without type or value raises, to be caught at the adapter boundary" do
      json = ~s({
        "head": {"vars": ["s"]},
        "results": {"bindings": [{"s": {"value": "missing-type"}}]}
      })

      assert_raise FunctionClauseError, fn -> Result.decode(json) end
    end
  end

  describe "decode!/1" do
    test "returns the result on success" do
      json = ~s({"head": {"vars": []}, "results": {"bindings": []}})
      assert %Result{variables: [], bindings: []} = Result.decode!(json)
    end

    test "raises on invalid input" do
      assert_raise RuntimeError, ~r/invalid SPARQL results JSON/, fn ->
        Result.decode!(~s({"foo": "bar"}))
      end
    end
  end

  describe "decode/1 (property-based)" do
    property "decodes any conforming SPARQL results document without losing a binding or raising" do
      check all(document <- sparql_results_document()) do
        json = Jason.encode!(document)

        assert {:ok, %Result{variables: variables, bindings: bindings}} = Result.decode(json)

        assert variables == document["head"]["vars"]
        assert length(bindings) == length(document["results"]["bindings"])

        Enum.zip(bindings, document["results"]["bindings"])
        |> Enum.each(fn {decoded_binding, raw_binding} ->
          assert Map.keys(decoded_binding) |> Enum.sort() == Map.keys(raw_binding) |> Enum.sort()
        end)
      end
    end
  end

  defp sparql_results_document do
    gen all(
          variables <- list_of(variable_name(), max_length: 5),
          bindings <- list_of(binding_generator(variables), max_length: 10)
        ) do
      %{"head" => %{"vars" => variables}, "results" => %{"bindings" => bindings}}
    end
  end

  defp binding_generator([]), do: constant(%{})

  defp binding_generator(variables) do
    variables
    |> Enum.map(fn name -> {name, binding_value()} end)
    |> fixed_map()
  end

  defp binding_value do
    gen all(
          type <- member_of(["uri", "literal", "bnode"]),
          value <- string(:printable, min_length: 1, max_length: 20),
          datatype <-
            one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 10)]),
          lang <- one_of([constant(nil), string(:alphanumeric, min_length: 2, max_length: 5)])
        ) do
      %{"type" => type, "value" => value}
      |> maybe_put("datatype", datatype)
      |> maybe_put("xml:lang", lang)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp variable_name do
    string(:alphanumeric, min_length: 1, max_length: 10)
  end
end
