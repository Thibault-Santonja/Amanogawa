defmodule Amanogawa.Atlas.TimeScaleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Atlas.TimeScale

  alias Amanogawa.Atlas.TimeScale

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "support",
                  "fixtures",
                  "time_scale",
                  "anchors.json"
                ])

  defp fixture do
    @fixture_path |> File.read!() |> Jason.decode!()
  end

  defp default_scale, do: TimeScale.default()

  describe "new/1" do
    test "builds the documented default domain with no overrides" do
      assert {:ok, %TimeScale{min_year: -300_000, max_year: 2_100, pivot: 10_000}} =
               TimeScale.new()
    end

    test "overrides individual fields" do
      assert {:ok, %TimeScale{min_year: -1000, max_year: 2_100, pivot: 10_000}} =
               TimeScale.new(min_year: -1000)
    end

    test "error case: rejects min_year >= max_year" do
      assert {:error, "min_year must be less than max_year"} =
               TimeScale.new(min_year: 100, max_year: 100)

      assert {:error, "min_year must be less than max_year"} =
               TimeScale.new(min_year: 200, max_year: 100)
    end

    test "error case: rejects a non-positive pivot" do
      assert {:error, "pivot must be a positive integer"} = TimeScale.new(pivot: 0)
      assert {:error, "pivot must be a positive integer"} = TimeScale.new(pivot: -1)
    end

    test "new!/1 raises ArgumentError on invalid input" do
      assert_raise ArgumentError, "min_year must be less than max_year", fn ->
        TimeScale.new!(min_year: 100, max_year: 0)
      end
    end
  end

  describe "position/2 and year/2 against the shared fixture" do
    test "every anchor round-trips within the fixture's tolerance" do
      %{"config" => config, "tolerance" => tolerance, "anchors" => anchors} = fixture()

      scale =
        TimeScale.new!(
          min_year: config["min_year"],
          max_year: config["max_year"],
          pivot: config["pivot"]
        )

      assert scale == default_scale()

      for %{"year" => year, "position" => expected_position} <- anchors do
        actual = TimeScale.position(scale, year)

        assert_in_delta actual,
                        expected_position,
                        tolerance,
                        "position(#{year}) = #{actual}, expected #{expected_position}"
      end
    end

    test "the fixture is well-formed and contains every documented mandatory anchor" do
      %{"anchors" => anchors} = fixture()
      years = MapSet.new(anchors, & &1["year"])

      mandatory = MapSet.new([-300_000, -100_000, -10_000, -490, 0, 1000, 1789, 2000, 2100])

      assert MapSet.subset?(mandatory, years)

      for anchor <- anchors do
        assert is_integer(anchor["year"])
        assert is_number(anchor["position"])
      end
    end
  end

  describe "position/2 limit cases" do
    test "position(min_year) is exactly 0.0 and position(max_year) is exactly 1.0" do
      scale = default_scale()

      assert TimeScale.position(scale, scale.min_year) == 0.0
      assert TimeScale.position(scale, scale.max_year) == 1.0
    end

    test "out-of-domain years are clamped, never raise" do
      scale = default_scale()

      assert TimeScale.position(scale, -1_000_000) == 0.0
      assert TimeScale.position(scale, 1_000_000) == 1.0
    end
  end

  describe "year/2 limit cases" do
    test "year(0.0) is min_year and year(1.0) is max_year" do
      scale = default_scale()

      assert TimeScale.year(scale, 0.0) == scale.min_year
      assert TimeScale.year(scale, 1.0) == scale.max_year
    end

    test "out-of-range positions are clamped, never raise" do
      scale = default_scale()

      assert TimeScale.year(scale, -1.0) == scale.min_year
      assert TimeScale.year(scale, 2.0) == scale.max_year
    end
  end

  describe "ticks/3 happy path" do
    test "a recent window returns round, strictly increasing years within the window" do
      scale = default_scale()

      ticks = TimeScale.ticks(scale, {1700, 2000}, 6)

      assert ticks == Enum.sort(ticks)
      assert ticks == Enum.uniq(ticks)
      assert Enum.all?(ticks, &(&1 >= 1700 and &1 <= 2000))
      assert length(ticks) >= 2
    end

    test "a step landing exactly on a power of ten picks that power of ten (nice_step residual <= 1)" do
      scale = default_scale()

      # range / count == 1000 exactly: `nice_step`'s residual (raw_step /
      # magnitude) is exactly 1.0, exercising its `residual <= 1` branch
      # rather than the `<= 2`/`<= 5`/`else` ones every other test here
      # happens to hit.
      ticks = TimeScale.ticks(scale, {-2000, 2000}, 4)

      assert ticks == [-2000, -1000, 0, 1000, 2000]
    end
  end

  describe "ticks/3 edge cases" do
    test "a window crossing the BP threshold returns coherent ticks on both sides" do
      scale = default_scale()

      ticks = TimeScale.ticks(scale, {-15_000, -5_000}, 6)

      assert ticks == Enum.sort(ticks)
      assert ticks == Enum.uniq(ticks)
      assert Enum.all?(ticks, &(&1 >= -15_000 and &1 <= -5_000))
      assert Enum.any?(ticks, &(&1 <= -10_000))
      assert Enum.any?(ticks, &(&1 > -10_000))
    end

    test "a very narrow window does not duplicate ticks and handles a one-year step" do
      scale = default_scale()

      ticks = TimeScale.ticks(scale, {1969, 1970}, 6)

      assert ticks == Enum.uniq(ticks)
      assert Enum.all?(ticks, &(&1 >= 1969 and &1 <= 1970))
    end

    test "a degenerate window (from == to) returns at most one tick" do
      scale = default_scale()

      ticks = TimeScale.ticks(scale, {1969, 1969}, 6)

      assert ticks == [1969]
    end

    test "from and to are swapped automatically when given in the wrong order" do
      scale = default_scale()

      assert TimeScale.ticks(scale, {2000, 1700}, 6) == TimeScale.ticks(scale, {1700, 2000}, 6)
    end
  end

  describe "accessors" do
    test "bp_threshold_year/0, bp_epoch/0 and default_tick_count/0 expose the documented constants" do
      assert TimeScale.bp_threshold_year() == -10_000
      assert TimeScale.bp_epoch() == 1950
      assert TimeScale.default_tick_count() == 6
    end
  end

  describe "property tests" do
    property "monotonicity: position(a) < position(b) for any a < b in the domain" do
      scale = default_scale()
      domain_size = scale.max_year - scale.min_year

      # `b` is built from `a` plus a positive gap, clamped to `max_year`,
      # rather than generated independently and filtered on `a < b`: with a
      # domain spanning 300k+ years, StreamData's early (small) generation
      # sizes make an independently generated pair collide often enough to
      # trip `StreamData.FilterTooNarrowError`. This construction guarantees
      # `b > a` by construction, no filtering needed.
      check all a <- integer(scale.min_year..(scale.max_year - 1)),
                gap <- integer(1..domain_size) do
        b = min(scale.max_year, a + gap)

        assert TimeScale.position(scale, a) < TimeScale.position(scale, b)
      end
    end

    property "round-trip: year(position(year)) is within 1 year of the original" do
      scale = default_scale()

      check all year <- integer(scale.min_year..scale.max_year) do
        round_tripped =
          year |> then(&TimeScale.position(scale, &1)) |> then(&TimeScale.year(scale, &1))

        assert_in_delta round_tripped, year, 1
      end
    end

    property "bounds: position(year) is always within [0.0, 1.0]" do
      scale = default_scale()

      check all year <- integer(scale.min_year..scale.max_year) do
        position = TimeScale.position(scale, year)

        assert position >= 0.0
        assert position <= 1.0
      end
    end

    property "ticks: always strictly increasing, duplicate-free, and contained in the window" do
      scale = default_scale()

      check all a <- integer(scale.min_year..scale.max_year),
                b <- integer(scale.min_year..scale.max_year),
                count <- integer(1..20) do
        from = min(a, b)
        to = max(a, b)

        ticks = TimeScale.ticks(scale, {from, to}, count)

        assert ticks == Enum.uniq(ticks)
        assert ticks == Enum.sort(ticks)
        assert Enum.all?(ticks, &(&1 >= from and &1 <= to))
      end
    end
  end
end
