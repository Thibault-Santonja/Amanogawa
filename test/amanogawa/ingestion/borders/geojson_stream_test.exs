defmodule Amanogawa.Ingestion.Borders.GeojsonStreamTest do
  use ExUnit.Case, async: true

  doctest Amanogawa.Ingestion.Borders.GeojsonStream

  alias Amanogawa.Ingestion.Borders.GeojsonStream

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

  describe "happy path" do
    test "reads every feature of a real-shaped fixture in order" do
      features = @cliopatria_fixture |> GeojsonStream.features() |> Enum.to_list()

      assert length(features) == 7
      assert Enum.all?(features, &match?({:ok, %{"type" => "Feature"}}, &1))

      names =
        Enum.map(features, fn {:ok, feature} -> get_in(feature, ["properties", "Name"]) end)

      assert names == [
               "Roman Empire",
               "Roman Empire",
               "Byzantine Empire",
               "Roman Empire administers Egypt",
               nil,
               "Bad Range Kingdom",
               "Degenerate Sliver"
             ]
    end

    test "is lazy: building it performs no I/O and never raises before enumeration" do
      # A nonexistent path never raises here: `File.stream!/3` only opens
      # the file lazily, on the first `Enum`/`Stream` operation that drives
      # the underlying `Stream.transform/4`.
      lazy = GeojsonStream.features("/nonexistent/path.geojson")
      assert Enumerable.impl_for(lazy)
    end
  end

  describe "edge case: chunk boundaries" do
    test "byte-by-byte chunking (chunk_bytes: 1) yields the exact same features as the default chunk size" do
      default = @cliopatria_fixture |> GeojsonStream.features() |> Enum.to_list()
      tiny = @cliopatria_fixture |> GeojsonStream.features(chunk_bytes: 1) |> Enum.to_list()

      assert tiny == default
    end

    test "quotes, escaped quotes, and braces/brackets inside string values never miscount depth" do
      path = write_tmp!(~s({"type":"FeatureCollection","features":[
        {"type":"Feature","properties":{"Name":"A \\"quoted\\" name, with {brace} and [bracket]"},"geometry":null}
      ]}))

      on_exit_delete(path)

      assert [{:ok, feature}] = GeojsonStream.features(path) |> Enum.to_list()
      assert feature["properties"]["Name"] == ~s(A "quoted" name, with {brace} and [bracket])
    end

    test "an empty features array yields no features" do
      path = write_tmp!(~s({"type":"FeatureCollection","features":[]}))
      on_exit_delete(path)

      assert GeojsonStream.features(path) |> Enum.to_list() == []
    end

    test "whitespace/newlines between features (pretty-printed GeoJSON) are tolerated" do
      path =
        write_tmp!("""
        {
          "type": "FeatureCollection",
          "features": [
            {"type": "Feature", "properties": {"a": 1}, "geometry": null},
            {"type": "Feature", "properties": {"a": 2}, "geometry": null}
          ]
        }
        """)

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}, {:ok, %{"properties" => %{"a" => 2}}}] =
               GeojsonStream.features(path) |> Enum.to_list()
    end

    test "content after the features array (a trailing top-level key) is ignored" do
      path =
        write_tmp!(
          ~s({"features":[{"type":"Feature","properties":{"a":1},"geometry":null}],"extra":{"anything":true}})
        )

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path) |> Enum.to_list()
    end
  end

  describe "error case: malformed JSON inside one feature" do
    test "tags the broken feature and keeps streaming the rest, never crashing the whole file" do
      path =
        write_tmp!(~s({"features":[
          {"type":"Feature","properties":{"a":1},"geometry":null},
          {"type":"Feature","properties":{"a": invalid_token}},
          {"type":"Feature","properties":{"a":3},"geometry":null}
        ]}))

      on_exit_delete(path)

      results = GeojsonStream.features(path) |> Enum.to_list()

      assert [
               {:ok, %{"properties" => %{"a" => 1}}},
               {:error, {:invalid_json, %Jason.DecodeError{}}},
               {:ok, %{"properties" => %{"a" => 3}}}
             ] = results
    end
  end

  describe "error case: non-object elements in the features array" do
    test "null, numbers and bare strings are each tagged, surrounding features still stream" do
      path =
        write_tmp!(
          ~s({"features":[{"type":"Feature","properties":{"a":1},"geometry":null},null,42,"junk",{"type":"Feature","properties":{"a":2},"geometry":null}]})
        )

      on_exit_delete(path)

      results = GeojsonStream.features(path) |> Enum.to_list()

      assert [
               {:ok, %{"properties" => %{"a" => 1}}},
               {:error, {:invalid_json, :non_object_feature}},
               {:error, {:invalid_json, :non_object_feature}},
               {:error, {:invalid_json, :non_object_feature}},
               {:ok, %{"properties" => %{"a" => 2}}}
             ] = results
    end

    test "a bare string element containing a comma is one rejected element, not two" do
      path = write_tmp!(~s({"features":["a, b",{"type":"Feature","properties":{"a":1}}]}))
      on_exit_delete(path)

      assert [
               {:error, {:invalid_json, :non_object_feature}},
               {:ok, %{"properties" => %{"a" => 1}}}
             ] = GeojsonStream.features(path) |> Enum.to_list()
    end

    test "a trailing non-object element right before the closing bracket is still tagged" do
      path = write_tmp!(~s({"features":[{"type":"Feature","properties":{"a":1}},null]}))
      on_exit_delete(path)

      assert [
               {:ok, %{"properties" => %{"a" => 1}}},
               {:error, {:invalid_json, :non_object_feature}}
             ] = GeojsonStream.features(path) |> Enum.to_list()
    end

    test "byte-by-byte chunking yields the exact same tagged errors" do
      content =
        ~s({"features":[null,{"type":"Feature","properties":{"a":1},"geometry":null},7]})

      path = write_tmp!(content)
      on_exit_delete(path)

      default = GeojsonStream.features(path) |> Enum.to_list()
      tiny = GeojsonStream.features(path, chunk_bytes: 1) |> Enum.to_list()

      assert tiny == default

      assert [
               {:error, {:invalid_json, :non_object_feature}},
               {:ok, _},
               {:error, {:invalid_json, :non_object_feature}}
             ] = default
    end
  end

  describe "error case: oversized feature (max_feature_bytes cap)" do
    test "a feature over the cap is rejected and counted, later features still stream" do
      big_name = String.duplicate("x", 300)

      path =
        write_tmp!(~s({"features":[
          {"type":"Feature","properties":{"Name":"#{big_name}"},"geometry":null},
          {"type":"Feature","properties":{"a":2},"geometry":null}
        ]}))

      on_exit_delete(path)

      results = GeojsonStream.features(path, max_feature_bytes: 128) |> Enum.to_list()

      assert [
               {:error, {:invalid_json, :feature_too_large}},
               {:ok, %{"properties" => %{"a" => 2}}}
             ] = results
    end

    test "the cap holds across chunk boundaries (chunk_bytes: 1)" do
      big_name = String.duplicate("x", 300)

      path =
        write_tmp!(
          ~s({"features":[{"type":"Feature","properties":{"Name":"#{big_name}"}},{"type":"Feature","properties":{"a":2}}]})
        )

      on_exit_delete(path)

      results =
        GeojsonStream.features(path, max_feature_bytes: 128, chunk_bytes: 1) |> Enum.to_list()

      assert [
               {:error, {:invalid_json, :feature_too_large}},
               {:ok, %{"properties" => %{"a" => 2}}}
             ] = results
    end

    test "a feature exactly at the cap is accepted" do
      feature_json = ~s({"type":"Feature","properties":{"a":1}})
      path = write_tmp!(~s({"features":[#{feature_json}]}))
      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path, max_feature_bytes: byte_size(feature_json))
               |> Enum.to_list()
    end
  end

  describe "edge case: \"features\" appearing inside header string values" do
    test "a header value equal to \"features\" never triggers a false array start" do
      path =
        write_tmp!(
          ~s({"title":"features","features":[{"type":"Feature","properties":{"a":1},"geometry":null}]})
        )

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path) |> Enum.to_list()
    end

    test "a header value containing '\"features\": [' inside a string is not the array" do
      path =
        write_tmp!(
          ~s({"description":"has \\"features\\": [1,2] inside","features":[{"type":"Feature","properties":{"a":1},"geometry":null}]})
        )

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path) |> Enum.to_list()
    end

    test "a nested object's own features key is not mistaken for the top-level one" do
      path =
        write_tmp!(
          ~s({"meta":{"features":"none"},"features":[{"type":"Feature","properties":{"a":1},"geometry":null}]})
        )

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path) |> Enum.to_list()
    end

    test "the seek stays correct byte by byte (chunk_bytes: 1)" do
      path =
        write_tmp!(
          ~s({"title":"features","features":[{"type":"Feature","properties":{"a":1},"geometry":null}]})
        )

      on_exit_delete(path)

      assert [{:ok, %{"properties" => %{"a" => 1}}}] =
               GeojsonStream.features(path, chunk_bytes: 1) |> Enum.to_list()
    end
  end

  describe "error case: no top-level \"features\" array" do
    test "raises a clear error rather than scanning the whole file" do
      path = write_tmp!(~s({"type":"NotAFeatureCollection"}))
      on_exit_delete(path)

      assert_raise RuntimeError, ~r/no top-level "features" array found/, fn ->
        GeojsonStream.features(path) |> Enum.to_list()
      end
    end
  end

  describe "error case: truncated file" do
    test "raises rather than silently returning a partial result" do
      path = write_tmp!(~s({"features":[{"type":"Feature"))
      on_exit_delete(path)

      assert_raise RuntimeError, ~r/ended while still in/, fn ->
        GeojsonStream.features(path) |> Enum.to_list()
      end
    end
  end

  defp write_tmp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "geojson_stream_test_#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, content)
    path
  end

  defp on_exit_delete(path), do: ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
end
