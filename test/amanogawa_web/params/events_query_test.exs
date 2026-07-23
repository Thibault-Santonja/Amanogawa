defmodule AmanogawaWeb.Params.EventsQueryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest AmanogawaWeb.Params.EventsQuery

  alias AmanogawaWeb.Params.EventsQuery

  @current_year Date.utc_today().year
  @min_year -13_800_000_000

  describe "parse/1 happy path" do
    test "parses bbox, from, to and limit into normalized options" do
      params = %{"bbox" => "2.0,48.0,3.0,49.0", "from" => "-500", "to" => "500", "limit" => "100"}

      assert {:ok, opts} = EventsQuery.parse(params)

      assert opts == %{
               envelopes: [%{min_lon: 2.0, min_lat: 48.0, max_lon: 3.0, max_lat: 49.0}],
               from: -500,
               to: 500,
               limit: 100
             }
    end

    test "accepts integer-typed params (as Plug would already have cast for some adapters)" do
      params = %{"bbox" => "2.0,48.0,3.0,49.0", "from" => -500, "to" => 500, "limit" => 100}

      assert {:ok, opts} = EventsQuery.parse(params)
      assert opts.from == -500
      assert opts.to == 500
      assert opts.limit == 100
    end
  end

  describe "parse/1 edge cases: defaults and antimeridian" do
    test "bbox crossing the antimeridian is decomposed into two envelopes" do
      assert {:ok, opts} = EventsQuery.parse(%{"bbox" => "170,-10,-170,10"})

      assert opts.envelopes == [
               %{min_lon: 170.0, min_lat: -10.0, max_lon: 180.0, max_lat: 10.0},
               %{min_lon: -180.0, min_lat: -10.0, max_lon: -170.0, max_lat: 10.0}
             ]
    end

    test "absent bbox defaults to the whole world" do
      assert {:ok, opts} = EventsQuery.parse(%{})

      assert opts.envelopes == [
               %{min_lon: -180.0, min_lat: -90.0, max_lon: 180.0, max_lat: 90.0}
             ]
    end

    test "absent from/to defaults to the full supported range" do
      assert {:ok, opts} = EventsQuery.parse(%{})

      assert opts.from == @min_year
      assert opts.to == @current_year
    end

    test "absent limit defaults to 500" do
      assert {:ok, opts} = EventsQuery.parse(%{})
      assert opts.limit == 500
    end
  end

  describe "parse/1 error cases" do
    test "bbox with 3 components is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"bbox" => "2.0,48.0,3.0"})
      assert [_message] = errors.bbox
    end

    test "bbox with 4 components but a non-numeric one is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"bbox" => "2.0,abc,3.0,49.0"})
      assert [_message] = errors.bbox
    end

    test "latitude out of [-90, 90] is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"bbox" => "2.0,-95.0,3.0,49.0"})
      assert [_message] = errors.bbox
    end

    test "longitude out of [-180, 180] is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"bbox" => "-200.0,48.0,3.0,49.0"})
      assert [_message] = errors.bbox
    end

    test "min_lat >= max_lat is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"bbox" => "2.0,49.0,3.0,49.0"})
      assert [_message] = errors.bbox
    end

    test "from > to is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"from" => "500", "to" => "-500"})
      assert [_message] = errors.from
    end

    test "year below the minimum supported year is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"from" => Integer.to_string(@min_year - 1)})
      assert [_message] = errors.from
    end

    test "year above the current year is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"to" => Integer.to_string(@current_year + 1)})
      assert [_message] = errors.to
    end

    test "a non-integer limit is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"limit" => "not-a-number"})
      assert [_message] = errors.limit
    end
  end

  describe "parse/1 limit cases" do
    test "limit=2000 is accepted as-is" do
      assert {:ok, %{limit: 2000}} = EventsQuery.parse(%{"limit" => "2000"})
    end

    test "limit=2001 is truncated to the server-side cap of 2000" do
      assert {:ok, %{limit: 2000}} = EventsQuery.parse(%{"limit" => "2001"})
    end

    test "limit=0 is rejected" do
      assert {:error, errors} = EventsQuery.parse(%{"limit" => "0"})
      assert [_message] = errors.limit
    end

    test "the exact lower year bound is accepted" do
      assert {:ok, %{from: @min_year}} =
               EventsQuery.parse(%{"from" => Integer.to_string(@min_year)})
    end

    test "the exact current year bound is accepted" do
      assert {:ok, %{to: @current_year}} =
               EventsQuery.parse(%{"to" => Integer.to_string(@current_year)})
    end
  end

  describe "parse_bbox/1 property" do
    property "any valid bbox (including antimeridian) decomposes into one or two envelopes within world bounds" do
      check all {min_lon, min_lat, max_lon, max_lat} <- valid_bbox_floats() do
        bbox_string = "#{min_lon},#{min_lat},#{max_lon},#{max_lat}"

        assert {:ok, envelopes} = EventsQuery.parse_bbox(bbox_string)
        assert length(envelopes) in [1, 2]

        for envelope <- envelopes do
          assert envelope.min_lon >= -180.0 and envelope.min_lon <= 180.0
          assert envelope.max_lon >= -180.0 and envelope.max_lon <= 180.0
          assert envelope.min_lat >= -90.0 and envelope.min_lat <= 90.0
          assert envelope.max_lat >= -90.0 and envelope.max_lat <= 90.0
          assert envelope.min_lon <= envelope.max_lon
          assert envelope.min_lat < envelope.max_lat
        end

        if min_lon > max_lon do
          assert length(envelopes) == 2
        else
          assert length(envelopes) == 1
        end
      end
    end
  end

  defp valid_bbox_floats do
    gen all min_lon <- float(min: -180.0, max: 180.0),
            max_lon <- float(min: -180.0, max: 180.0),
            lat_a <- float(min: -90.0, max: 90.0),
            lat_b <- float(min: -90.0, max: 90.0),
            lat_a != lat_b do
      min_lat = min(lat_a, lat_b)
      max_lat = max(lat_a, lat_b)
      {min_lon, min_lat, max_lon, max_lat}
    end
  end
end
