defmodule Amanogawa.Ingestion.Cliopatria.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.Cliopatria.Parser

  alias Amanogawa.Ingestion.Cliopatria.Parser

  @polygon %{
    "type" => "Polygon",
    "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]
  }

  describe "happy path" do
    test "a well-formed POLITY feature is parsed into a full row" do
      feature = %{
        "properties" => %{
          "Name" => "Roman Empire",
          "FromYear" => -27,
          "ToYear" => 395,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) ==
               {:ok,
                %{
                  name: "Roman Empire",
                  from_year: -27,
                  to_year: 395,
                  geometry: @polygon,
                  precision: nil
                }}
    end

    test "a feature with no Type property defaults to POLITY (lenient)" do
      feature = %{
        "properties" => %{"Name" => "Roman Empire", "FromYear" => -27, "ToYear" => 395},
        "geometry" => @polygon
      }

      assert {:ok, _row} = Parser.parse_feature(feature)
    end
  end

  describe "edge case: MultiPolygon geometry, negative years, superfluous properties" do
    test "a MultiPolygon geometry is accepted as-is" do
      multi = %{"type" => "MultiPolygon", "coordinates" => [@polygon["coordinates"]]}

      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -500,
          "ToYear" => -100,
          "Type" => "POLITY"
        },
        "geometry" => multi
      }

      assert {:ok, %{geometry: ^multi}} = Parser.parse_feature(feature)
    end

    test "negative from_year and to_year are correctly signed" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -3400,
          "ToYear" => -3000,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert {:ok, %{from_year: -3400, to_year: -3000}} = Parser.parse_feature(feature)
    end

    test "superfluous properties (Area, Wikipedia, Wikidata, SeshatID) are ignored" do
      feature = %{
        "properties" => %{
          "Name" => "Roman Empire",
          "FromYear" => -27,
          "ToYear" => 395,
          "Type" => "POLITY",
          "Area" => 4_400_000,
          "Wikipedia" => "Roman_Empire",
          "Wikidata" => "Q2277",
          "SeshatID" => 71
        },
        "geometry" => @polygon
      }

      assert {:ok, row} = Parser.parse_feature(feature)
      assert Map.keys(row) |> Enum.sort() == [:from_year, :geometry, :name, :precision, :to_year]
    end

    test "whole-valued float years are normalized to integers" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -27.0,
          "ToYear" => 395.0,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert {:ok, %{from_year: -27, to_year: 395}} = Parser.parse_feature(feature)
    end

    test "a RELATION row is skipped, not an error" do
      feature = %{
        "properties" => %{
          "Name" => "A relation",
          "FromYear" => 1,
          "ToYear" => 2,
          "Type" => "RELATION"
        },
        "geometry" => nil
      }

      assert Parser.parse_feature(feature) == :skip
    end
  end

  describe "error case: malformed or incomplete features" do
    test "a missing Name produces a tagged error" do
      feature = %{
        "properties" => %{"FromYear" => 1, "ToYear" => 2, "Type" => "POLITY"},
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:missing_or_invalid_property, "Name"}}
    end

    test "a missing FromYear produces a tagged error" do
      feature = %{
        "properties" => %{"Name" => "Empire", "ToYear" => 2, "Type" => "POLITY"},
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:missing_or_invalid_property, "FromYear"}}
    end

    test "a missing ToYear produces a tagged error" do
      feature = %{
        "properties" => %{"Name" => "Empire", "FromYear" => 1, "Type" => "POLITY"},
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:missing_or_invalid_property, "ToYear"}}
    end

    test "a non-whole float year produces a tagged error" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => 1.5,
          "ToYear" => 2,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:missing_or_invalid_property, "FromYear"}}
    end

    test "from_year > to_year produces a tagged error rather than crashing later insertion" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => 100,
          "ToYear" => 50,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:invalid_year_range, 100, 50}}
    end

    test "a non-polygon geometry type produces a tagged error" do
      feature = %{
        "properties" => %{"Name" => "Empire", "FromYear" => 1, "ToYear" => 2, "Type" => "POLITY"},
        "geometry" => %{"type" => "Point", "coordinates" => [0.0, 0.0]}
      }

      assert Parser.parse_feature(feature) == {:error, :invalid_geometry_type}
    end

    test "a feature without properties or geometry keys is a tagged error, not a crash" do
      assert Parser.parse_feature(%{"not" => "a feature"}) ==
               {:error, :missing_properties_or_geometry}
    end
  end

  describe "error case: hostile geometry coordinates" do
    test "null coordinates produce a tagged error" do
      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => nil})
    end

    test "string coordinates produce a tagged error" do
      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => "not a list"})
    end

    test "a Polygon nested like a MultiPolygon (one level too deep) produces a tagged error" do
      too_deep = [[[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0]]]]

      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => too_deep})
    end

    test "a MultiPolygon nested like a Polygon (one level too shallow) produces a tagged error" do
      too_shallow = [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0]]]

      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "MultiPolygon", "coordinates" => too_shallow})
    end

    test "empty coordinates (or an empty ring) produce a tagged error" do
      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => []})

      assert {:error, :invalid_geometry_coordinates} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => [[]]})
    end

    test "a position that is not 2-3 numbers produces a tagged error" do
      one_number = [[[0.0], [0.0, 1.0], [1.0, 1.0], [0.0]]]
      four_numbers = [[[0.0, 0.0, 0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [0.0, 0.0, 0.0, 0.0]]]
      strings = [[["a", "b"], [0.0, 1.0], [1.0, 1.0], ["a", "b"]]]

      for coordinates <- [one_number, four_numbers, strings] do
        assert {:error, :invalid_geometry_coordinates} =
                 parse_with_geometry(%{"type" => "Polygon", "coordinates" => coordinates})
      end
    end

    test "longitude or latitude out of the WGS84 domain produces a tagged error" do
      bad_lon = [[[181.0, 0.0], [0.0, 1.0], [1.0, 1.0], [181.0, 0.0]]]
      bad_lat = [[[0.0, -91.0], [0.0, 1.0], [1.0, 1.0], [0.0, -91.0]]]

      for coordinates <- [bad_lon, bad_lat] do
        assert {:error, :invalid_geometry_coordinates} =
                 parse_with_geometry(%{"type" => "Polygon", "coordinates" => coordinates})
      end
    end

    test "a 3-element position (with elevation) is accepted" do
      with_elevation = [
        [[0.0, 0.0, 12.5], [0.0, 1.0, 12.5], [1.0, 1.0, 12.5], [0.0, 0.0, 12.5]]
      ]

      assert {:ok, _row} =
               parse_with_geometry(%{"type" => "Polygon", "coordinates" => with_elevation})
    end
  end

  describe "error case: implausible or overflowing years" do
    test "a year far beyond the int4 domain is rejected, never crashes the SQL batch" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -13_800_000_000,
          "ToYear" => 2024,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) ==
               {:error, {:year_out_of_bounds, "FromYear", -13_800_000_000}}
    end

    test "a year outside the plausibility window [-200_000, 3000] is rejected" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -27,
          "ToYear" => 3001,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:year_out_of_bounds, "ToYear", 3001}}
    end

    test "the plausibility window's own bounds are accepted" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -200_000,
          "ToYear" => 3000,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert {:ok, %{from_year: -200_000, to_year: 3000}} = Parser.parse_feature(feature)
    end
  end

  describe "error case: oversized name" do
    test "a name over 500 characters is rejected with a tagged error, never truncated" do
      megabyte_name = String.duplicate("x", 1_048_576)

      feature = %{
        "properties" => %{
          "Name" => megabyte_name,
          "FromYear" => -27,
          "ToYear" => 395,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert Parser.parse_feature(feature) == {:error, {:name_too_long, 1_048_576}}
    end

    test "a name of exactly 500 characters is accepted" do
      name = String.duplicate("x", 500)

      feature = %{
        "properties" => %{"Name" => name, "FromYear" => -27, "ToYear" => 395, "Type" => "POLITY"},
        "geometry" => @polygon
      }

      assert {:ok, %{name: ^name}} = Parser.parse_feature(feature)
    end
  end

  describe "limit case" do
    test "from_year == to_year is accepted" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => 100,
          "ToYear" => 100,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert {:ok, %{from_year: 100, to_year: 100}} = Parser.parse_feature(feature)
    end

    test "the dataset's documented bounds (-3400 and 2024) are accepted" do
      feature = %{
        "properties" => %{
          "Name" => "Empire",
          "FromYear" => -3400,
          "ToYear" => 2024,
          "Type" => "POLITY"
        },
        "geometry" => @polygon
      }

      assert {:ok, %{from_year: -3400, to_year: 2024}} = Parser.parse_feature(feature)
    end
  end

  describe "property: year normalization never crashes and is tagged" do
    property "for any pair of signed years, parsing succeeds ordered or fails tagged, never raises" do
      check all from_year <- integer(-300_000..300_000),
                to_year <- integer(-300_000..300_000),
                max_runs: 100 do
        feature = %{
          "properties" => %{
            "Name" => "Empire",
            "FromYear" => from_year,
            "ToYear" => to_year,
            "Type" => "POLITY"
          },
          "geometry" => @polygon
        }

        in_bounds = fn year -> year >= -200_000 and year <= 3000 end

        case Parser.parse_feature(feature) do
          {:ok, %{from_year: ^from_year, to_year: ^to_year}} ->
            assert from_year <= to_year
            assert in_bounds.(from_year) and in_bounds.(to_year)

          {:error, {:invalid_year_range, ^from_year, ^to_year}} ->
            assert from_year > to_year

          {:error, {:year_out_of_bounds, _key, year}} ->
            refute in_bounds.(year)
        end
      end
    end

    property "absent or wrong-typed properties never raise, only ever a tagged :error or :skip" do
      check all properties <- random_properties(), max_runs: 100 do
        feature = %{"properties" => properties, "geometry" => @polygon}

        assert match?({:ok, _}, Parser.parse_feature(feature)) or
                 match?({:error, _}, Parser.parse_feature(feature)) or
                 Parser.parse_feature(feature) == :skip
      end
    end
  end

  defp parse_with_geometry(geometry) do
    Parser.parse_feature(%{
      "properties" => %{
        "Name" => "Empire",
        "FromYear" => -27,
        "ToYear" => 395,
        "Type" => "POLITY"
      },
      "geometry" => geometry
    })
  end

  defp random_properties do
    gen all name <- one_of([string(:printable), constant(nil), integer()]),
            from_year <- one_of([integer(), string(:printable), constant(nil)]),
            to_year <- one_of([integer(), string(:printable), constant(nil)]),
            type <-
              one_of([
                constant("POLITY"),
                constant("RELATION"),
                constant(nil),
                string(:printable)
              ]) do
      %{"Name" => name, "FromYear" => from_year, "ToYear" => to_year, "Type" => type}
    end
  end
end
