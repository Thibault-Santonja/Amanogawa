defmodule Amanogawa.Ingestion.HistoricalBasemaps.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.HistoricalBasemaps.Parser

  alias Amanogawa.Ingestion.HistoricalBasemaps.Parser

  @polygon %{
    "type" => "Polygon",
    "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]
  }

  describe "parse_feature/1: happy path" do
    test "a well-formed feature with NAME and BORDERPRECISION is parsed" do
      feature = %{
        "properties" => %{"NAME" => "Natufian culture", "BORDERPRECISION" => 1},
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) ==
               {:ok, %{name: "Natufian culture", geometry: @polygon, precision: 1}}
    end
  end

  describe "parse_feature/1: edge case" do
    test "a feature without NAME is skipped, not an error" do
      feature = %{
        "properties" => %{"NAME" => nil, "BORDERPRECISION" => 1},
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == :skip
    end

    test "an empty NAME is skipped" do
      feature = %{"properties" => %{"NAME" => "", "BORDERPRECISION" => 1}, "geometry" => @polygon}
      assert Parser.parse_feature(feature) == :skip
    end

    test "an absent BORDERPRECISION gives precision: nil" do
      feature = %{"properties" => %{"NAME" => "Natufian culture"}, "geometry" => @polygon}

      assert Parser.parse_feature(feature) ==
               {:ok, %{name: "Natufian culture", geometry: @polygon, precision: nil}}
    end
  end

  describe "parse_feature/1: error case" do
    test "an invalid geometry type produces a tagged error" do
      feature = %{
        "properties" => %{"NAME" => "Natufian culture"},
        "geometry" => %{"type" => "LineString", "coordinates" => [[0.0, 0.0], [1.0, 1.0]]}
      }

      assert Parser.parse_feature(feature) == {:error, :invalid_geometry_type}
    end

    test "a feature without properties or geometry keys is a tagged error" do
      assert Parser.parse_feature(%{"not" => "a feature"}) ==
               {:error, :missing_properties_or_geometry}
    end
  end

  describe "parse_filename_year/1: happy path" do
    test "a BCE filename maps to a negative year" do
      assert Parser.parse_filename_year("world_bc4000.geojson") == {:ok, -4000}
    end

    test "a CE filename maps to a positive year" do
      assert Parser.parse_filename_year("world_1000.geojson") == {:ok, 1000}
    end
  end

  describe "parse_filename_year/1: error case" do
    test "an unrecognized filename produces a tagged error" do
      assert Parser.parse_filename_year("places.geojson") ==
               {:error, {:unrecognized_filename, "places.geojson"}}
    end

    test "a non-.geojson extension is unrecognized" do
      assert Parser.parse_filename_year("world_bc4000.json") ==
               {:error, {:unrecognized_filename, "world_bc4000.json"}}
    end
  end

  describe "slice_intervals/1: happy path" do
    test "sorted tranches produce contiguous intervals, last bounded to -3401" do
      assert Parser.slice_intervals([-123_000, -10_000, -8_000, -5_000, -4_000]) == [
               %{year: -123_000, from_year: -123_000, to_year: -10_001},
               %{year: -10_000, from_year: -10_000, to_year: -8_001},
               %{year: -8_000, from_year: -8_000, to_year: -5_001},
               %{year: -5_000, from_year: -5_000, to_year: -4_001},
               %{year: -4_000, from_year: -4_000, to_year: -3_401}
             ]
    end

    test "an unsorted input list is sorted before mapping" do
      assert Parser.slice_intervals([-4_000, -123_000, -8_000]) == [
               %{year: -123_000, from_year: -123_000, to_year: -8_001},
               %{year: -8_000, from_year: -8_000, to_year: -4_001},
               %{year: -4_000, from_year: -4_000, to_year: -3_401}
             ]
    end
  end

  describe "slice_intervals/1: edge case" do
    test "a single tranche produces [year, -3401]" do
      assert Parser.slice_intervals([-5_000]) == [
               %{year: -5_000, from_year: -5_000, to_year: -3_401}
             ]
    end

    test "an empty list produces an empty list" do
      assert Parser.slice_intervals([]) == []
    end

    test "a duplicated year is deduplicated before mapping" do
      assert Parser.slice_intervals([-5_000, -5_000, -4_000]) == [
               %{year: -5_000, from_year: -5_000, to_year: -4_001},
               %{year: -4_000, from_year: -4_000, to_year: -3_401}
             ]
    end
  end

  describe "slice_intervals/1: limit case" do
    test "a tranche exactly at -3400 is excluded" do
      assert Parser.slice_intervals([-3_400]) == []
    end

    test "a tranche at -3401 is included with from_year == to_year == -3401" do
      assert Parser.slice_intervals([-3_401]) == [
               %{year: -3_401, from_year: -3_401, to_year: -3_401}
             ]
    end

    test "years >= -3400 mixed with valid ones are dropped, valid ones still processed" do
      assert Parser.slice_intervals([-5_000, -3_400, 100]) == [
               %{year: -5_000, from_year: -5_000, to_year: -3_401}
             ]
    end
  end

  describe "slice_intervals/1: property" do
    property "intervals are contiguous, non-overlapping, and cover [first tranche, -3401]" do
      check all years <- uniq_list_of(integer(-500_000..-3401), min_length: 1, max_length: 30),
                max_runs: 100 do
        intervals = Parser.slice_intervals(years)
        sorted = Enum.sort(years)

        assert Enum.map(intervals, & &1.year) == sorted
        assert List.last(intervals).to_year == -3401
        assert hd(intervals).from_year == hd(sorted)

        # Contiguous, non-overlapping: each interval's to_year is exactly
        # one less than the next interval's from_year.
        intervals
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.each(fn [a, b] -> assert a.to_year == b.from_year - 1 end)

        # Every interval is well-ordered.
        assert Enum.all?(intervals, &(&1.from_year <= &1.to_year))
      end
    end
  end
end
