defmodule AmanogawaWeb.Params.ExploreParamsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest AmanogawaWeb.Params.ExploreParams

  alias AmanogawaWeb.Params.ExploreParams

  @current_year Date.utc_today().year
  @min_year Amanogawa.HistoricalDate.min_year()

  describe "parse/1 happy path" do
    test "parses a full valid URL into the expected state" do
      params = %{
        "from" => "-500",
        "to" => "500",
        "sel" => "Q123",
        "z" => "3.5",
        "lat" => "48.85",
        "lng" => "2.35"
      }

      assert ExploreParams.parse(params) == %{
               from: -500,
               to: 500,
               selected_qid: "Q123",
               z: 3.5,
               lat: 48.85,
               lng: 2.35
             }
    end
  end

  describe "parse/1 edge cases: defaults" do
    test "empty params fall back to the default view" do
      assert ExploreParams.parse(%{}) == %{
               from: @min_year,
               to: @current_year,
               selected_qid: nil,
               z: 1.5,
               lat: 20.0,
               lng: 0.0
             }
    end

    test "partial params are completed with defaults for the missing fields" do
      state = ExploreParams.parse(%{"z" => "5"})

      assert state.z == 5.0
      assert state.from == @min_year
      assert state.to == @current_year
      assert state.selected_qid == nil
    end

    test "negative years at the extreme are valid" do
      state = ExploreParams.parse(%{"from" => Integer.to_string(@min_year)})
      assert state.from == @min_year
    end
  end

  describe "parse/1 error cases" do
    test "from > to resets the whole window to the default, not just one bound" do
      state = ExploreParams.parse(%{"from" => "500", "to" => "-500"})

      assert state.from == @min_year
      assert state.to == @current_year
    end

    test "a malformed sel falls back to no selection, other fields stay intact" do
      state = ExploreParams.parse(%{"sel" => "not-a-qid", "from" => "-100"})

      assert state.selected_qid == nil
      assert state.from == -100
    end

    test "z out of bounds falls back to the default zoom" do
      assert ExploreParams.parse(%{"z" => "23"}).z == 1.5
      assert ExploreParams.parse(%{"z" => "-1"}).z == 1.5
    end

    test "lat/lng out of bounds fall back to their defaults" do
      assert ExploreParams.parse(%{"lat" => "91"}).lat == 20.0
      assert ExploreParams.parse(%{"lng" => "181"}).lng == 0.0
    end

    test "non-numeric values fall back to defaults without raising" do
      state =
        ExploreParams.parse(%{"from" => "abc", "z" => "abc", "lat" => "abc", "lng" => "abc"})

      assert state.from == @min_year
      assert state.z == 1.5
      assert state.lat == 20.0
      assert state.lng == 0.0
    end
  end

  describe "parse/1 limit cases" do
    test "the exact bounds are accepted as-is" do
      state =
        ExploreParams.parse(%{
          "from" => Integer.to_string(@min_year),
          "to" => Integer.to_string(@current_year),
          "z" => "0",
          "lat" => "90",
          "lng" => "-180"
        })

      assert state.from == @min_year
      assert state.to == @current_year
      assert state.z == 0.0
      assert state.lat == 90.0
      assert state.lng == -180.0

      state = ExploreParams.parse(%{"z" => "22"})
      assert state.z == 22.0
    end
  end

  describe "valid_window?/2 (issue #021)" do
    test "happy path: a well-formed, ordered window inside the domain is valid" do
      assert ExploreParams.valid_window?(-500, 500)
    end

    test "edge case: a window narrower than the minimum width is invalid" do
      refute ExploreParams.valid_window?(500, 500)
    end

    test "edge case: an inverted window (from > to) is invalid" do
      refute ExploreParams.valid_window?(500, -500)
    end

    test "error case: non-integer bounds are invalid, never raise" do
      refute ExploreParams.valid_window?("abc", "def")
      refute ExploreParams.valid_window?(1.5, 2.5)
      refute ExploreParams.valid_window?(nil, nil)
    end

    test "error case: a bound outside the domain is invalid" do
      refute ExploreParams.valid_window?(@min_year - 1, 500)
      refute ExploreParams.valid_window?(-500, @current_year + 1)
    end

    test "limit case: a window exactly at the minimum width is valid" do
      assert ExploreParams.valid_window?(500, 501)
    end

    test "limit case: bounds exactly on the domain's own edges are valid" do
      assert ExploreParams.valid_window?(@min_year, @current_year)
    end

    property "invariant: valid_window?/2 accepts exactly the well-formed, in-domain, minimum-width windows" do
      check all from <- integer(),
                to <- integer() do
        expected =
          from >= @min_year and from <= @current_year and
            to >= @min_year and to <= @current_year and
            to - from >= 1

        assert ExploreParams.valid_window?(from, to) == expected
      end
    end
  end

  describe "to_query/1" do
    test "round-trips a nominal state through parse/1" do
      state = %{
        from: -500,
        to: 500,
        selected_qid: "Q123",
        z: 3.5,
        lat: 48.85,
        lng: 2.35
      }

      assert ExploreParams.parse(ExploreParams.to_query(state)) == state
    end

    test "the default state encodes to an empty query" do
      default = ExploreParams.parse(%{})
      assert ExploreParams.to_query(default) == %{}
    end
  end

  describe "property: round-trip" do
    property "encoding then parsing a valid state returns the same state" do
      check all state <- valid_state() do
        assert ExploreParams.parse(ExploreParams.to_query(state)) == state
      end
    end
  end

  describe "property: hostile input" do
    property "parse/1 never raises and always returns a state within bounds" do
      check all params <- hostile_params() do
        state = ExploreParams.parse(params)

        assert state.from >= @min_year and state.from <= @current_year
        assert state.to >= @min_year and state.to <= @current_year
        assert state.from <= state.to

        assert is_nil(state.selected_qid) or state.selected_qid =~ ~r/\AQ\d+\z/

        assert state.z >= 0 and state.z <= 22
        assert state.lat >= -90.0 and state.lat <= 90.0
        assert state.lng >= -180.0 and state.lng <= 180.0
      end
    end
  end

  defp valid_state do
    gen all from <- integer(@min_year..@current_year),
            to <- integer(from..@current_year),
            selected_qid <- one_of([constant(nil), qid()]),
            z <- float(min: 0.0, max: 22.0),
            lat <- float(min: -90.0, max: 90.0),
            lng <- float(min: -180.0, max: 180.0) do
      %{from: from, to: to, selected_qid: selected_qid, z: z, lat: lat, lng: lng}
    end
  end

  defp qid do
    gen all n <- integer(1..999_999) do
      "Q#{n}"
    end
  end

  defp hostile_value do
    one_of([
      string(:printable, max_length: 20),
      integer(),
      float(),
      constant(nil),
      boolean(),
      list_of(string(:printable, max_length: 10), max_length: 3),
      constant(%{})
    ])
  end

  defp hostile_params do
    gen all from <- hostile_value(),
            to <- hostile_value(),
            sel <- hostile_value(),
            z <- hostile_value(),
            lat <- hostile_value(),
            lng <- hostile_value() do
      %{
        "from" => from,
        "to" => to,
        "sel" => sel,
        "z" => z,
        "lat" => lat,
        "lng" => lng
      }
    end
  end
end
