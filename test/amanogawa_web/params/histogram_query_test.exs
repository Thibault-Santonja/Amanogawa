defmodule AmanogawaWeb.Params.HistogramQueryTest do
  use ExUnit.Case, async: true

  alias AmanogawaWeb.Params.HistogramQuery

  # The single time-window domain (F04 decision D1):
  # `Amanogawa.Atlas.TimeScale.default/0`'s bounds, upper bound the
  # current UTC year.
  @min_year -300_000
  @max_year Date.utc_today().year

  describe "parse/1 happy path" do
    test "parses from, to and buckets into normalized options" do
      params = %{"from" => "-500", "to" => "500", "buckets" => "50"}

      assert {:ok, opts} = HistogramQuery.parse(params)
      assert opts == %{from: -500, to: 500, buckets: 50}
    end

    test "accepts integer-typed params" do
      params = %{"from" => -500, "to" => 500, "buckets" => 50}

      assert {:ok, opts} = HistogramQuery.parse(params)
      assert opts == %{from: -500, to: 500, buckets: 50}
    end

    test "absent buckets defaults to 100" do
      assert {:ok, %{buckets: 100}} = HistogramQuery.parse(%{"from" => "0", "to" => "100"})
    end
  end

  describe "parse/1 error cases" do
    test "missing from is rejected, never silently defaulted" do
      assert {:error, errors} = HistogramQuery.parse(%{"to" => "100"})
      assert [_message] = errors.from
    end

    test "missing to is rejected, never silently defaulted" do
      assert {:error, errors} = HistogramQuery.parse(%{"from" => "0"})
      assert [_message] = errors.to
    end

    test "from >= to is rejected (strictly less than, unlike EventsQuery)" do
      assert {:error, errors} = HistogramQuery.parse(%{"from" => "500", "to" => "500"})
      assert [_message] = errors.from

      assert {:error, errors} = HistogramQuery.parse(%{"from" => "500", "to" => "-500"})
      assert [_message] = errors.from
    end

    test "from below the TimeScale domain is rejected" do
      params = %{"from" => Integer.to_string(@min_year - 1), "to" => "0"}
      assert {:error, errors} = HistogramQuery.parse(params)
      assert [_message] = errors.from
    end

    test "to above the TimeScale domain is rejected" do
      params = %{"from" => "0", "to" => Integer.to_string(@max_year + 1)}
      assert {:error, errors} = HistogramQuery.parse(params)
      assert [_message] = errors.to
    end

    test "buckets below 1 is rejected" do
      params = %{"from" => "0", "to" => "100", "buckets" => "0"}
      assert {:error, errors} = HistogramQuery.parse(params)
      assert [_message] = errors.buckets
    end

    test "buckets above 200 is rejected" do
      params = %{"from" => "0", "to" => "100", "buckets" => "201"}
      assert {:error, errors} = HistogramQuery.parse(params)
      assert [_message] = errors.buckets
    end

    test "a non-integer buckets is rejected" do
      params = %{"from" => "0", "to" => "100", "buckets" => "not-a-number"}
      assert {:error, errors} = HistogramQuery.parse(params)
      assert [_message] = errors.buckets
    end
  end

  describe "parse/1 limit cases" do
    test "the exact domain bounds are accepted" do
      params = %{"from" => Integer.to_string(@min_year), "to" => Integer.to_string(@max_year)}
      assert {:ok, %{from: @min_year, to: @max_year}} = HistogramQuery.parse(params)
    end

    test "buckets=1 is accepted" do
      params = %{"from" => "0", "to" => "100", "buckets" => "1"}
      assert {:ok, %{buckets: 1}} = HistogramQuery.parse(params)
    end

    test "buckets=200 is accepted" do
      params = %{"from" => "0", "to" => "100", "buckets" => "200"}
      assert {:ok, %{buckets: 200}} = HistogramQuery.parse(params)
    end
  end
end
