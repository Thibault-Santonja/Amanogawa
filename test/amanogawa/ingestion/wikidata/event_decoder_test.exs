defmodule Amanogawa.Ingestion.Wikidata.EventDecoderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Ingestion.Wikidata.EventDecoder

  alias Amanogawa.HistoricalDate
  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.Wikidata.EventDecoder
  alias Amanogawa.SparqlFixtures

  @gregorian_calendar_uri "http://www.wikidata.org/entity/Q1985727"

  describe "decode/1 happy path" do
    test "decodes a real nominal page into ExtractedEvent structs with correct provenance and sitelinks" do
      {:ok, result} = SparqlFixtures.sparql_fixture("events_page.json")

      {events, rejected} = EventDecoder.decode(result)

      assert rejected == 0
      assert length(events) == length(result.bindings)
      assert Enum.all?(events, &Regex.match?(~r/\AQ\d+\z/, &1.qid))

      mohacs = Enum.find(events, &(&1.qid == "Q178510"))
      assert mohacs.location_source == :direct
      assert %Geo.Point{srid: 4326} = mohacs.geom
      assert mohacs.begin.precision == 11
      assert mohacs.sitelink_count > 0
    end

    test "decodes the Marathon regression fixture with the direct coordinate" do
      {:ok, result} = SparqlFixtures.sparql_fixture("marathon.json")

      {[event], 0} = EventDecoder.decode(result)

      assert event.qid == "Q31900"
      assert event.location_source == :direct
      assert event.begin.calendar == :julian
    end
  end

  describe "decode/1 regression: RDF astronomical year convention (battle of Marathon)" do
    test "the RDF year -0489 decodes to the internal astronomical year -489 (490 BCE), unshifted" do
      {:ok, result} = SparqlFixtures.sparql_fixture("marathon.json")

      {[event], 0} = EventDecoder.decode(result)

      # The RDF/SPARQL channel is already astronomical (unlike the JSON dump
      # channel, which needs a +1 shift): no correction is applied here.
      # -489 is year 490 BCE (ADR 0006).
      assert event.begin.year == -489
    end
  end

  describe "decode/1 regression: coherent (time, precision, calendar) triplet on multi-statement events" do
    test "an event with two P585 statements of different precisions decodes one coherent triplet, never a mix" do
      # See test/support/fixtures/sparql/README.md, mixed_precision_begin:
      # the sampled token is entirely the year-precision statement
      # (-0490, precision 9, Gregorian). Under independent per-field
      # sampling, this event could decode as the incoherent
      # "-0490 at precision 11, Julian" (one statement's time with the
      # other's precision and calendar).
      {:ok, result} = SparqlFixtures.sparql_fixture("mixed_precision_begin.json")

      {[event], 0} = EventDecoder.decode(result)

      assert event.qid == "Q31900"

      assert event.begin == %HistoricalDate{
               year: -490,
               month: nil,
               day: nil,
               precision: 9,
               calendar: :gregorian
             }
    end
  end

  describe "decode/1 edge cases" do
    test "an event with only inherited (place) coordinates gets location_source: :place" do
      {:ok, result} = SparqlFixtures.sparql_fixture("events_page.json")
      {events, 0} = EventDecoder.decode(result)

      mellrichstadt = Enum.find(events, &(&1.qid == "Q178219"))
      assert mellrichstadt.location_source == :place
    end

    test "an event with no French or English article has nil wiki urls" do
      {:ok, result} = SparqlFixtures.sparql_fixture("events_page.json")
      {events, 0} = EventDecoder.decode(result)

      no_article = Enum.find(events, &(&1.qid == "Q178530"))
      assert no_article.wiki_url_fr == nil
      assert no_article.wiki_url_en == nil
    end

    test "an event with both a begin and an end date decodes both" do
      {:ok, result} = SparqlFixtures.sparql_fixture("events_page.json")
      {events, 0} = EventDecoder.decode(result)

      syrian_civil_war = Enum.find(events, &(&1.qid == "Q178810"))
      assert %HistoricalDate{} = syrian_civil_war.begin
      assert %HistoricalDate{} = syrian_civil_war.end
    end

    test "a class (kind) URI that is not a plain QID is dropped without rejecting the event" do
      result =
        single_binding_result(%{
          "kind" => uri("http://www.wikidata.org/entity/statement/Q1-not-a-class")
        })

      {[event], 0} = EventDecoder.decode(result)

      assert event.kind == nil
    end

    test "precision 7 (century) truncates month and day" do
      result = single_binding_result(%{"beginToken" => begin_token("-0700-01-01T00:00:00Z", 7)})

      {[event], 0} = EventDecoder.decode(result)

      assert event.begin.precision == 7
      assert event.begin.month == nil
      assert event.begin.day == nil
    end

    test "WKT coordinates without decimals parse through the integer fallback" do
      result = single_binding_result(%{"coordDirect" => literal("POINT(10 20)")})

      {[event], 0} = EventDecoder.decode(result)

      assert event.geom.coordinates == {10.0, 20.0}
    end

    test "a lowercase Point(...) WKT literal is accepted (case-insensitive match)" do
      result = single_binding_result(%{"coordDirect" => literal("Point(2.35 48.85)")})

      {[event], 0} = EventDecoder.decode(result)

      assert event.geom.coordinates == {2.35, 48.85}
    end

    test "exponential notation within WGS84 bounds parses" do
      result = single_binding_result(%{"coordDirect" => literal("POINT(1.5e2 -4.5E1)")})

      {[event], 0} = EventDecoder.decode(result)

      assert event.geom.coordinates == {150.0, -45.0}
    end

    test "a malformed sitelink count defaults to 0 instead of rejecting the event" do
      result = single_binding_result(%{"sitelinkCount" => literal("not-a-number")})

      {[event], 0} = EventDecoder.decode(result)

      assert event.sitelink_count == 0
    end

    test "an absurd sitelink count is clamped into 0..1_000_000" do
      huge = single_binding_result(%{"sitelinkCount" => literal("999999999999")})
      negative = single_binding_result(%{"sitelinkCount" => literal("-5")})

      {[huge_event], 0} = EventDecoder.decode(huge)
      {[negative_event], 0} = EventDecoder.decode(negative)

      assert huge_event.sitelink_count == 1_000_000
      assert negative_event.sitelink_count == 0
    end

    test "labels and descriptions longer than 512 characters are truncated, not rejected" do
      long = String.duplicate("é", 700)

      result = single_binding_result(%{"labelFr" => literal(long), "descEn" => literal(long)})

      {[event], 0} = EventDecoder.decode(result)

      assert String.length(event.label_fr) == 512
      assert String.length(event.description_en) == 512
    end
  end

  describe "decode/1 error cases" do
    test "hostile bindings (token missing precision, malformed WKT, non-entity URI, unparsable time) are all rejected, none crash" do
      {:ok, result} = SparqlFixtures.sparql_fixture("hostile_bindings.json")

      {events, rejected} = EventDecoder.decode(result)

      assert events == []
      assert rejected == length(result.bindings)
    end

    test "a begin token with the wrong arity is rejected" do
      result = single_binding_result(%{"beginToken" => literal("1900-01-01T00:00:00Z|9")})

      assert EventDecoder.decode(result) == {[], 1}
    end

    test "a non-string coordinate value (defensive: never produced by real JSON decoding) is rejected" do
      result =
        single_binding_result(%{
          "coordDirect" => %{value: 123, type: :literal, datatype: nil, lang: nil}
        })

      assert EventDecoder.decode(result) == {[], 1}
    end

    test "an event with neither a direct nor an inherited coordinate is rejected" do
      result = single_binding_result(%{"coordDirect" => :drop})

      assert EventDecoder.decode(result) == {[], 1}
    end

    test "WKT coordinates outside the WGS84 domain are rejected" do
      out_of_range = single_binding_result(%{"coordDirect" => literal("POINT(200 10)")})
      huge_exponent = single_binding_result(%{"coordDirect" => literal("POINT(1e99 0)")})

      too_many_digits =
        single_binding_result(%{"coordDirect" => literal("POINT(123456789012345 0)")})

      assert EventDecoder.decode(out_of_range) == {[], 1}
      assert EventDecoder.decode(huge_exponent) == {[], 1}
      assert EventDecoder.decode(too_many_digits) == {[], 1}
    end

    test "a wiki article URL that is not https on a Wikimedia host rejects the binding" do
      http = single_binding_result(%{"articleFr" => uri("http://fr.wikipedia.org/wiki/X")})

      hostile = single_binding_result(%{"articleEn" => uri("https://evil.example.com/wiki/X")})

      too_long =
        single_binding_result(%{
          "articleFr" => uri("https://fr.wikipedia.org/wiki/" <> String.duplicate("a", 3000))
        })

      assert EventDecoder.decode(http) == {[], 1}
      assert EventDecoder.decode(hostile) == {[], 1}
      assert EventDecoder.decode(too_long) == {[], 1}
    end

    test "a begin year outside [-13_800_000_000, 3000] is rejected, never a crash" do
      too_deep =
        single_binding_result(%{"beginToken" => begin_token("-99999999999-01-01T00:00:00Z", 0)})

      too_far = single_binding_result(%{"beginToken" => begin_token("5000-01-01T00:00:00Z", 9)})

      assert EventDecoder.decode(too_deep) == {[], 1}
      assert EventDecoder.decode(too_far) == {[], 1}
    end
  end

  describe "decode/1 limit cases" do
    test "an empty page decodes to an empty list with zero rejections" do
      {:ok, result} = SparqlFixtures.sparql_fixture("empty.json")

      assert EventDecoder.decode(result) == {[], 0}
    end

    test "a deeply prehistoric year (-123000) decodes correctly" do
      {:ok, result} = SparqlFixtures.sparql_fixture("prehistory.json")

      {[event], 0} = EventDecoder.decode(result)

      assert event.begin.year == -123_000
      assert event.begin.month == nil
      assert event.begin.day == nil
    end
  end

  describe "property: decode/1 on synthetic bindings" do
    property "never raises and every decoded event respects the domain invariants" do
      check all bindings <- list_of(synthetic_binding(), max_length: 20) do
        result = %Result{variables: [], bindings: bindings}

        {events, rejected} = EventDecoder.decode(result)

        assert rejected >= 0
        assert length(events) + rejected == length(bindings)

        for event <- events do
          assert Regex.match?(~r/\AQ\d+\z/, event.qid)
          assert event.geom.srid == 4326

          if event.begin.precision <= 9 do
            assert event.begin.month == nil
            assert event.begin.day == nil
          end

          assert event.location_source in [:direct, :place]
        end
      end
    end

    property "WKT round-trip: parsing 'POINT(lon lat)' recovers the original coordinates" do
      check all lon <- float(min: -180.0, max: 180.0),
                lat <- float(min: -90.0, max: 90.0) do
        lon_str = :erlang.float_to_binary(lon, decimals: 6)
        lat_str = :erlang.float_to_binary(lat, decimals: 6)

        result =
          single_binding_result(%{"coordDirect" => literal("POINT(#{lon_str} #{lat_str})")})

        {[event], 0} = EventDecoder.decode(result)
        {decoded_lon, decoded_lat} = event.geom.coordinates

        assert_in_delta decoded_lon, lon, 1.0e-5
        assert_in_delta decoded_lat, lat, 1.0e-5
      end
    end
  end

  # --- helpers ---------------------------------------------------------

  # A valid single-binding page; `overrides` replaces or (with :drop as the
  # value) removes keys from the base binding.
  defp single_binding_result(overrides) do
    base = %{
      "e" => uri("Q900020"),
      "beginToken" => begin_token("1900-01-01T00:00:00Z", 9),
      "coordDirect" => literal("POINT(10 20)")
    }

    binding =
      Enum.reduce(overrides, base, fn
        {key, :drop}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)

    %Result{variables: Map.keys(binding), bindings: [binding]}
  end

  defp begin_token(time, precision) do
    literal("#{time}|#{precision}|#{@gregorian_calendar_uri}")
  end

  defp synthetic_binding do
    gen all qid_num <- integer(1..999_999_999),
            year <- integer(-200_000..2100),
            precision <- integer(0..11),
            {month, day} <- synthetic_month_day(precision),
            lon <- float(min: -180.0, max: 180.0),
            lat <- float(min: -90.0, max: 90.0),
            coord_key <- member_of(["coordDirect", "coordPlace"]) do
      %{
        "e" => uri("Q#{qid_num}"),
        "beginToken" =>
          literal(
            "#{synthetic_time_string(year, month, day)}|#{precision}|#{@gregorian_calendar_uri}"
          ),
        coord_key =>
          literal(
            "POINT(#{:erlang.float_to_binary(lon, decimals: 6)} #{:erlang.float_to_binary(lat, decimals: 6)})"
          )
      }
    end
  end

  defp synthetic_month_day(precision) when precision <= 9, do: constant({1, 1})

  defp synthetic_month_day(_precision) do
    gen all month <- integer(1..12), day <- integer(1..28) do
      {month, day}
    end
  end

  defp synthetic_time_string(year, month, day) do
    sign = if year < 0, do: "-", else: "+"
    year_digits = year |> abs() |> Integer.to_string() |> String.pad_leading(4, "0")
    month_digits = month |> Integer.to_string() |> String.pad_leading(2, "0")
    day_digits = day |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{sign}#{year_digits}-#{month_digits}-#{day_digits}T00:00:00Z"
  end

  defp uri(qid_or_url)

  defp uri("http" <> _rest = url), do: %{value: url, type: :uri, datatype: nil, lang: nil}

  defp uri(qid),
    do: %{value: "http://www.wikidata.org/entity/#{qid}", type: :uri, datatype: nil, lang: nil}

  defp literal(value), do: %{value: value, type: :literal, datatype: nil, lang: nil}
end
