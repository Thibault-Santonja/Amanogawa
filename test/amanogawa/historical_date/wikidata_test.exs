defmodule Amanogawa.HistoricalDate.WikidataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.HistoricalDate.Wikidata

  import Amanogawa.HistoricalDateGenerators

  alias Amanogawa.HistoricalDate
  alias Amanogawa.HistoricalDate.Wikidata

  @gregorian_uri "http://www.wikidata.org/entity/Q1985727"
  @julian_uri "http://www.wikidata.org/entity/Q1985786"

  describe "from_rdf/1 happy path" do
    test "keeps the RDF year as-is (already astronomical): battle of Marathon" do
      assert {:ok,
              %HistoricalDate{year: -489, month: 9, day: 12, precision: 11, calendar: :julian}} =
               Wikidata.from_rdf(%{
                 time: "-0489-09-12T00:00:00Z",
                 precision: 11,
                 calendar: @julian_uri
               })
    end

    test "maps the gregorian calendar QID" do
      assert {:ok, %HistoricalDate{calendar: :gregorian}} =
               Wikidata.from_rdf(%{
                 time: "1789-07-14T00:00:00Z",
                 precision: 11,
                 calendar: @gregorian_uri
               })
    end
  end

  describe "from_json/1 happy path" do
    test "shifts negative years by +1: same battle of Marathon, JSON encoding" do
      assert {:ok,
              %HistoricalDate{year: -489, month: 9, day: 12, precision: 11, calendar: :julian}} =
               Wikidata.from_json(%{
                 time: "-0490-09-12T00:00:00Z",
                 precision: 11,
                 calendar: @julian_uri
               })
    end

    test "does not shift positive years" do
      assert {:ok, %HistoricalDate{year: 1789}} =
               Wikidata.from_json(%{
                 time: "1789-07-14T00:00:00Z",
                 precision: 11,
                 calendar: @gregorian_uri
               })
    end
  end

  describe "edge cases" do
    test "precision <= 9 truncates the fake January 1st month/day" do
      assert {:ok, %HistoricalDate{year: 1789, month: nil, day: nil}} =
               Wikidata.from_rdf(%{
                 time: "1789-01-01T00:00:00Z",
                 precision: 9,
                 calendar: @gregorian_uri
               })
    end

    test "precision 10 keeps month, truncates day" do
      assert {:ok, %HistoricalDate{year: 1789, month: 7, day: nil}} =
               Wikidata.from_rdf(%{
                 time: "1789-07-01T00:00:00Z",
                 precision: 10,
                 calendar: @gregorian_uri
               })
    end
  end

  describe "error cases" do
    test "an unparsable time string returns a tagged error" do
      assert {:error, {:invalid_time, "not-a-date"}} =
               Wikidata.from_rdf(%{time: "not-a-date", precision: 11, calendar: @gregorian_uri})
    end

    test "an unrecognized calendar URI returns a tagged error" do
      assert {:error, {:invalid_calendar, _}} =
               Wikidata.from_rdf(%{
                 time: "1789-07-14T00:00:00Z",
                 precision: 11,
                 calendar: "http://www.wikidata.org/entity/Q999999"
               })
    end

    test "a non-binary time value returns a tagged error" do
      assert {:error, {:invalid_time, 12_345}} =
               Wikidata.from_rdf(%{time: 12_345, precision: 9, calendar: @gregorian_uri})
    end

    test "a non-binary calendar value returns a tagged error" do
      assert {:error, {:invalid_calendar, nil}} =
               Wikidata.from_rdf(%{time: "1789-01-01T00:00:00Z", precision: 9, calendar: nil})
    end
  end

  describe "limit cases" do
    test "from_json on -0001-... gives year 0" do
      assert {:ok, %HistoricalDate{year: 0}} =
               Wikidata.from_json(%{
                 time: "-0001-01-01T00:00:00Z",
                 precision: 9,
                 calendar: @gregorian_uri
               })
    end

    test "from_rdf on 0000-... gives year 0" do
      assert {:ok, %HistoricalDate{year: 0}} =
               Wikidata.from_rdf(%{
                 time: "0000-01-01T00:00:00Z",
                 precision: 9,
                 calendar: @gregorian_uri
               })
    end

    test "parses years with more than 4 digits (deep prehistory)" do
      assert {:ok, %HistoricalDate{year: -123_000}} =
               Wikidata.from_rdf(%{
                 time: "-123000-01-01T00:00:00Z",
                 precision: 6,
                 calendar: @gregorian_uri
               })
    end
  end

  property "round-trip: RDF and JSON representations of the same date normalize to the same value" do
    check all date <- historical_date() do
      rdf_input = to_rdf_input(date)
      json_input = to_json_input(date)

      # The Wikidata time-string format cannot express "month/day unknown"
      # at precision 10/11 (unknown parts serialize as "01"), so a partial
      # date round-trips to its 01-filled equivalent, never to nil parts.
      expected = wire_representable(date)

      assert {:ok, ^expected} = Wikidata.from_rdf(rdf_input)
      assert {:ok, ^expected} = Wikidata.from_json(json_input)
    end
  end

  defp wire_representable(%HistoricalDate{precision: 11} = date),
    do: %{date | month: date.month || 1, day: date.day || 1}

  defp wire_representable(%HistoricalDate{precision: 10} = date),
    do: %{date | month: date.month || 1, day: nil}

  defp wire_representable(date), do: date

  defp to_rdf_input(%HistoricalDate{} = date) do
    %{
      time: time_string(date.year, date.month, date.day),
      precision: date.precision,
      calendar: calendar_uri(date.calendar)
    }
  end

  defp to_json_input(%HistoricalDate{} = date) do
    json_year = if date.year <= 0, do: date.year - 1, else: date.year

    %{
      time: time_string(json_year, date.month, date.day),
      precision: date.precision,
      calendar: calendar_uri(date.calendar)
    }
  end

  defp time_string(year, month, day) do
    sign = if year < 0, do: "-", else: "+"
    year_digits = year |> abs() |> Integer.to_string() |> String.pad_leading(4, "0")
    month_digits = (month || 1) |> Integer.to_string() |> String.pad_leading(2, "0")
    day_digits = (day || 1) |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{year_digits}-#{month_digits}-#{day_digits}T00:00:00Z"
  end

  defp calendar_uri(:gregorian), do: @gregorian_uri
  defp calendar_uri(:julian), do: @julian_uri
end
