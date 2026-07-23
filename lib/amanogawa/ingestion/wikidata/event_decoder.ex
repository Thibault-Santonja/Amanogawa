defmodule Amanogawa.Ingestion.Wikidata.EventDecoder do
  @moduledoc """
  Decodes a `Amanogawa.Ingestion.SparqlClient.Result` produced by
  `Amanogawa.Ingestion.Wikidata.Templates` into a list of
  `Amanogawa.Ingestion.Wikidata.ExtractedEvent`.

  A binding is rejected, never crashed on, when it is missing data the
  domain cannot do without: no parsable QID, no parsable date (via
  `Amanogawa.HistoricalDate.Wikidata.from_rdf/1`, which also carries the RDF
  astronomical-year convention and the precision-driven month/day
  truncation), or no parsable coordinate. One bad binding must never lose an
  entire page of otherwise-good events (`decode/1` returns a rejection
  count precisely so the caller, `Amanogawa.Ingestion.Workers.ImportEvents`,
  can track and report data quality without treating it as failure).

  Coordinate resolution is priority-based, never a silent fallback across a
  parse failure: a present but malformed `coordDirect` rejects the whole
  binding rather than quietly falling back to `coordPlace`, since that would
  mask a real data or decoding problem behind a plausible-looking event.

  ## Examples

      iex> result = %Amanogawa.Ingestion.SparqlClient.Result{
      ...>   variables: ["e", "beginTime", "beginPrecision", "beginCalendar", "coordDirect"],
      ...>   bindings: [
      ...>     %{
      ...>       "e" => %{value: "http://www.wikidata.org/entity/Q31900", type: :uri, datatype: nil, lang: nil},
      ...>       "beginTime" => %{value: "-0489-09-05T00:00:00Z", type: :literal, datatype: nil, lang: nil},
      ...>       "beginPrecision" => %{value: "11", type: :literal, datatype: nil, lang: nil},
      ...>       "beginCalendar" => %{value: "http://www.wikidata.org/entity/Q1985786", type: :uri, datatype: nil, lang: nil},
      ...>       "coordDirect" => %{value: "POINT(23.978333 38.118056)", type: :literal, datatype: nil, lang: nil}
      ...>     }
      ...>   ]
      ...> }
      iex> {[event], rejected} = Amanogawa.Ingestion.Wikidata.EventDecoder.decode(result)
      iex> {event.qid, event.begin.year, rejected}
      {"Q31900", -489, 0}

  """

  alias Amanogawa.HistoricalDate
  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.Wikidata.ExtractedEvent

  @qid_uri_regex ~r{^http://www\.wikidata\.org/entity/(Q\d+)$}
  @wkt_point_regex ~r/^POINT\(\s*([-+]?\d+(?:\.\d+)?)\s+([-+]?\d+(?:\.\d+)?)\s*\)$/

  @doc """
  Decodes every binding of `result` into an `ExtractedEvent`.

  Returns `{events, rejected_count}`: `events` in the same order as the
  input bindings, `rejected_count` the number of bindings dropped for
  lacking a parsable QID, date, or coordinate. Never raises on malformed
  input; a decode failure removes exactly one entry, never the whole batch.
  """
  @spec decode(Result.t()) :: {[ExtractedEvent.t()], non_neg_integer()}
  def decode(%Result{bindings: bindings}) do
    {events, rejected} =
      Enum.reduce(bindings, {[], 0}, fn binding, {events, rejected} ->
        case decode_binding(binding) do
          {:ok, event} -> {[event | events], rejected}
          :error -> {events, rejected + 1}
        end
      end)

    {Enum.reverse(events), rejected}
  end

  defp decode_binding(binding) do
    with {:ok, qid} <- extract_qid(binding),
         {:ok, begin_date} <-
           extract_date(binding, "beginTime", "beginPrecision", "beginCalendar"),
         {:ok, geom, location_source} <- extract_location(binding) do
      {:ok,
       %ExtractedEvent{
         qid: qid,
         label_fr: text(binding, "labelFr"),
         label_en: text(binding, "labelEn"),
         description_fr: text(binding, "descFr"),
         description_en: text(binding, "descEn"),
         kind: extract_kind(binding),
         begin: begin_date,
         end: optional_date(binding, "endTime", "endPrecision", "endCalendar"),
         geom: geom,
         location_source: location_source,
         wiki_url_fr: text(binding, "articleFr"),
         wiki_url_en: text(binding, "articleEn"),
         sitelink_count: integer(binding, "sitelinkCount", 0)
       }}
    else
      :error -> :error
    end
  end

  defp extract_qid(binding) do
    with {:ok, uri} <- fetch_value(binding, "e"),
         [_, qid] <- Regex.run(@qid_uri_regex, uri) do
      {:ok, qid}
    else
      _ -> :error
    end
  end

  defp extract_date(binding, time_key, precision_key, calendar_key) do
    with {:ok, time} <- fetch_value(binding, time_key),
         {:ok, precision_str} <- fetch_value(binding, precision_key),
         {:ok, precision} <- parse_integer(precision_str),
         {:ok, calendar} <- fetch_value(binding, calendar_key),
         {:ok, date} <-
           HistoricalDate.Wikidata.from_rdf(%{
             time: time,
             precision: precision,
             calendar: calendar
           }) do
      {:ok, date}
    else
      _ -> :error
    end
  end

  defp optional_date(binding, time_key, precision_key, calendar_key) do
    case extract_date(binding, time_key, precision_key, calendar_key) do
      {:ok, date} -> date
      :error -> nil
    end
  end

  defp extract_location(binding) do
    case fetch_value(binding, "coordDirect") do
      {:ok, wkt} -> with_point(wkt, :direct)
      :error -> extract_place_location(binding)
    end
  end

  defp extract_place_location(binding) do
    case fetch_value(binding, "coordPlace") do
      {:ok, wkt} -> with_point(wkt, :place)
      :error -> :error
    end
  end

  defp with_point(wkt, source) do
    case parse_wkt_point(wkt) do
      {:ok, point} -> {:ok, point, source}
      :error -> :error
    end
  end

  defp extract_kind(binding) do
    case fetch_value(binding, "kind") do
      {:ok, uri} ->
        case Regex.run(@qid_uri_regex, uri) do
          [_, qid] -> qid
          nil -> nil
        end

      :error ->
        nil
    end
  end

  defp text(binding, key) do
    case fetch_value(binding, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp integer(binding, key, default) do
    case fetch_value(binding, key) do
      {:ok, value} ->
        case parse_integer(value) do
          {:ok, int} -> int
          :error -> default
        end

      :error ->
        default
    end
  end

  defp fetch_value(binding, key) do
    case Map.fetch(binding, key) do
      {:ok, %{value: value}} -> {:ok, value}
      :error -> :error
    end
  end

  defp parse_integer(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  # WKT longitude comes first, latitude second (`POINT(lon lat)`): the
  # opposite order of the (lat, lon) most humans expect, and the single
  # detail most likely to be silently transposed by a careless rewrite.
  #
  # `@wkt_point_regex` only matches a `[-+]?\d+(\.\d+)?` shape for each
  # coordinate, a format `Float.parse/1` always accepts (including
  # integer-formatted strings: "10" parses to `{10.0, ""}`), so once the
  # regex has matched, parsing the two captured groups cannot fail.
  defp parse_wkt_point(wkt) when is_binary(wkt) do
    case Regex.run(@wkt_point_regex, wkt) do
      [_, lon_str, lat_str] ->
        {:ok, %Geo.Point{coordinates: {parse_number(lon_str), parse_number(lat_str)}, srid: 4326}}

      nil ->
        :error
    end
  end

  defp parse_wkt_point(_), do: :error

  defp parse_number(str) do
    {float, ""} = Float.parse(str)
    float
  end
end
