defmodule Amanogawa.Atlas.EventTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.HistoricalDateGenerators

  alias Amanogawa.Atlas.Event
  alias Amanogawa.HistoricalDate

  @valid_attrs %{
    qid: "Q46335",
    label_fr: "Bataille de Marathon",
    begin_year: -489,
    begin_precision: 9,
    location_source: :direct,
    geom: %Geo.Point{coordinates: {23.9750, 38.1128}, srid: 4326}
  }

  describe "changeset/2 happy path" do
    test "valid with a BCE date, Point SRID 4326 and location_source :place" do
      changeset = Event.changeset(%Event{}, %{@valid_attrs | location_source: :place})

      assert changeset.valid?
      assert get_field(changeset, :begin_year) == -489
    end

    test "valid with both a begin and an end date" do
      attrs =
        Map.merge(@valid_attrs, %{
          end_year: -480,
          end_month: 8,
          end_day: 1,
          end_precision: 11
        })

      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :end_year) == -480
      assert get_field(changeset, :end_month) == 8
    end
  end

  describe "changeset/2 edge cases" do
    test "an event without an end date leaves end_* columns nil" do
      changeset = Event.changeset(%Event{}, @valid_attrs)

      assert changeset.valid?
      assert get_field(changeset, :end_year) == nil
      assert get_field(changeset, :end_precision) == nil
    end

    test "a prehistoric event (begin_year -123000, precision 6) is accepted" do
      attrs = %{@valid_attrs | begin_year: -123_000, begin_precision: 6}
      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
    end

    test "an event without a geometry is accepted (nil geom)" do
      attrs = Map.delete(@valid_attrs, :geom)
      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :geom) == nil
    end

    test "flattening a HistoricalDate and reading it back round-trips" do
      date = HistoricalDate.new!(%{year: 1789, month: 7, day: 14, precision: 11})
      flat = Event.flatten_date(date, :begin)

      changeset = Event.changeset(%Event{}, Map.merge(@valid_attrs, flat))
      event = apply_action!(changeset, :insert)

      assert Event.begin_date(event) == date
    end

    test "flattening nil clears the begin_* or end_* columns" do
      assert Event.flatten_date(nil, :begin) == %{
               begin_year: nil,
               begin_month: nil,
               begin_day: nil,
               begin_precision: nil,
               begin_calendar: nil
             }

      assert Event.flatten_date(nil, :end) == %{
               end_year: nil,
               end_month: nil,
               end_day: nil,
               end_precision: nil,
               end_calendar: nil
             }
    end

    test "flattening a HistoricalDate into end_* columns and reading it back round-trips" do
      date = HistoricalDate.new!(%{year: -480, month: 8, day: 1, precision: 11})
      flat = Event.flatten_date(date, :end)

      changeset = Event.changeset(%Event{}, Map.merge(@valid_attrs, flat))
      event = apply_action!(changeset, :insert)

      assert Event.end_date(event) == date
    end

    test "end_date/1 returns nil when the event has no end date" do
      event = apply_action!(Event.changeset(%Event{}, @valid_attrs), :insert)

      assert Event.end_date(event) == nil
    end
  end

  describe "changeset/2 error cases" do
    test "a malformed QID is rejected" do
      changeset = Event.changeset(%Event{}, %{@valid_attrs | qid: "not-a-qid"})

      refute changeset.valid?
      assert "must be a Wikidata QID, e.g. Q12345" in errors_on(changeset).qid
    end

    test "begin_month with begin_precision 9 is truncated, not rejected (same rule as #006)" do
      attrs = Map.merge(@valid_attrs, %{begin_month: 7, begin_precision: 9})
      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
      assert get_field(changeset, :begin_month) == nil
    end

    test "an out-of-range begin_precision is rejected" do
      changeset = Event.changeset(%Event{}, %{@valid_attrs | begin_precision: 42})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).begin_precision
    end

    test "an out-of-range begin_month is rejected" do
      attrs = Map.merge(@valid_attrs, %{begin_precision: 11, begin_month: 13, begin_day: 1})
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "must be between 1 and 12" in errors_on(changeset).begin_month
    end

    test "an out-of-range begin_day is rejected" do
      attrs = Map.merge(@valid_attrs, %{begin_precision: 11, begin_month: 9, begin_day: 32})
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "must be between 1 and 31" in errors_on(changeset).begin_day
    end

    test "an end_day given without an end_month is rejected" do
      attrs = Map.merge(@valid_attrs, %{end_year: -480, end_day: 1, end_precision: 11})
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "is required when day is present" in errors_on(changeset).end_month
    end

    test "an out-of-range end_day is rejected" do
      attrs =
        Map.merge(@valid_attrs, %{end_year: -480, end_month: 8, end_day: 32, end_precision: 11})

      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "must be between 1 and 31" in errors_on(changeset).end_day
    end

    test "an out-of-range end_precision is rejected" do
      attrs = Map.merge(@valid_attrs, %{end_year: -480, end_precision: 42})
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).end_precision
    end

    test "a geometry with the wrong SRID is rejected" do
      attrs = %{@valid_attrs | geom: %Geo.Point{coordinates: {1.0, 1.0}, srid: 3857}}
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "must have SRID 4326" in errors_on(changeset).geom
    end

    test "a non-Point geometry is rejected" do
      polygon = %Geo.Polygon{
        coordinates: [[{0.0, 0.0}, {1.0, 0.0}, {1.0, 1.0}, {0.0, 0.0}]],
        srid: 4326
      }

      attrs = %{@valid_attrs | geom: polygon}
      changeset = Event.changeset(%Event{}, attrs)

      refute changeset.valid?
      assert "must be a Point geometry" in errors_on(changeset).geom
    end
  end

  describe "changeset/2 limit cases" do
    test "very long labels and extracts are accepted (text columns)" do
      long_text = String.duplicate("a", 10_000)
      attrs = Map.merge(@valid_attrs, %{label_fr: long_text, extract_fr: long_text})

      changeset = Event.changeset(%Event{}, attrs)

      assert changeset.valid?
    end

    test "sitelink_count 0 is accepted" do
      changeset = Event.changeset(%Event{}, Map.put(@valid_attrs, :sitelink_count, 0))

      assert changeset.valid?
      assert get_field(changeset, :sitelink_count) == 0
    end
  end

  property "flattening any generated HistoricalDate and reading it back round-trips" do
    check all date <- historical_date() do
      flat = Event.flatten_date(date, :begin)
      attrs = Map.merge(@valid_attrs, flat)

      event = apply_action!(Event.changeset(%Event{}, attrs), :insert)

      assert Event.begin_date(event) == date
    end
  end
end
