defmodule Amanogawa.Ingestion.Wikidata.EventDecoder do
  @moduledoc """
  Decodes a `Amanogawa.Ingestion.SparqlClient.Result` produced by
  `Amanogawa.Ingestion.Wikidata.Templates` into a list of
  `Amanogawa.Ingestion.Wikidata.ExtractedEvent`.

  A binding is rejected, never crashed on, when it is missing data the
  domain cannot do without: no parsable QID, no parsable date (via
  `Amanogawa.HistoricalDate.Wikidata.from_rdf/1`, which also carries the RDF
  astronomical-year convention, the precision-driven month/day truncation
  and the year bounds), or no parsable coordinate. One bad binding must
  never lose an entire page of otherwise-good events (`decode/1` returns a
  rejection count precisely so the caller,
  `Amanogawa.Ingestion.Workers.ImportEvents`, can track and report data
  quality without treating it as failure).

  Dates arrive as a single `time|precision|calendar` token per bound
  (`beginToken`/`endToken`), sampled server-side by
  `Amanogawa.Ingestion.Wikidata.Templates` as one `CONCAT` so the three
  parts always come from the same Wikidata statement (an event with several
  `P585` statements, like Q31900, must never mix one statement's time with
  another's precision). The token is split back into its three parts here.

  Coordinate resolution is priority-based, never a silent fallback across a
  parse failure: a present but malformed `coordDirect` rejects the whole
  binding rather than quietly falling back to `coordPlace`, since that would
  mask a real data or decoding problem behind a plausible-looking event.

  ## Input bounds

  External values are bounded before anything is handed to storage:

    * labels and descriptions are truncated to #{inspect(512)} characters
      (a Wikidata label past that length is display noise, not data worth
      rejecting a whole event over);
    * article URLs (`articleFr`/`articleEn`) must satisfy
      `Amanogawa.WikimediaUrl.valid?/1` (https, Wikimedia host,
      at most 2048 characters), otherwise the binding is rejected: a
      non-Wikimedia article URL means the binding cannot be trusted;
    * `sitelinkCount` is clamped into `0..1_000_000` (a malformed or absent
      count decodes to `0`, consistent with the clamp's lower bound);
    * WKT coordinates are matched against a bounded pattern (at most ten
      integer digits, ten decimal digits and a two-digit exponent per
      coordinate) and validated against the WGS84 domain (longitude
      [-180, 180], latitude [-90, 90]); anything else rejects the binding,
      including a `Float.parse/1` result that is not a full parse.

  ## Examples

      iex> result = %Amanogawa.Ingestion.SparqlClient.Result{
      ...>   variables: ["e", "beginToken", "coordDirect"],
      ...>   bindings: [
      ...>     %{
      ...>       "e" => %{value: "http://www.wikidata.org/entity/Q31900", type: :uri, datatype: nil, lang: nil},
      ...>       "beginToken" => %{value: "-0489-09-05T00:00:00Z|11|http://www.wikidata.org/entity/Q1985786", type: :literal, datatype: nil, lang: nil},
      ...>       "coordDirect" => %{value: "POINT(23.978333 38.118056)", type: :literal, datatype: nil, lang: nil}
      ...>     }
      ...>   ]
      ...> }
      iex> {[event], rejected} = Amanogawa.Ingestion.Wikidata.EventDecoder.decode(result)
      iex> {event.qid, event.begin.year, event.begin.precision, rejected}
      {"Q31900", -489, 11, 0}

  """

  alias Amanogawa.HistoricalDate
  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.Wikidata.ExtractedEvent
  alias Amanogawa.WikimediaUrl

  @qid_uri_regex ~r{\Ahttp://www\.wikidata\.org/entity/(Q\d+)\z}

  # Bounded on purpose: at most ten integer digits, ten decimal digits and
  # a two-digit exponent per coordinate. Within those bounds the largest
  # representable magnitude (~1e109) stays far under the float overflow
  # threshold (~1.8e308) at which `Float.parse/1` raises, so parsing a
  # matched capture can never crash; out-of-range values are then rejected
  # by the WGS84 domain check.
  @wkt_number "[-+]?\\d{1,10}(?:\\.\\d{1,10})?(?:[eE][-+]?\\d{1,2})?"
  @wkt_point_regex ~r/\APOINT\(\s*(#{@wkt_number})\s+(#{@wkt_number})\s*\)\z/i

  @max_text_length 512
  @max_sitelink_count 1_000_000

  @doc """
  Decodes every binding of `result` into an `ExtractedEvent`.

  Returns `{events, rejected_count}`: `events` in the same order as the
  input bindings, `rejected_count` the number of bindings dropped for
  lacking a parsable QID, date, or coordinate, or carrying an out-of-bounds
  value (see "Input bounds" in the moduledoc). Never raises on malformed
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
         {:ok, begin_date} <- extract_date(binding, "beginToken"),
         {:ok, geom, location_source} <- extract_location(binding),
         {:ok, wiki_url_fr} <- extract_wiki_url(binding, "articleFr"),
         {:ok, wiki_url_en} <- extract_wiki_url(binding, "articleEn") do
      {:ok,
       %ExtractedEvent{
         qid: qid,
         label_fr: bounded_text(binding, "labelFr"),
         label_en: bounded_text(binding, "labelEn"),
         description_fr: bounded_text(binding, "descFr"),
         description_en: bounded_text(binding, "descEn"),
         kind: extract_kind(binding),
         begin: begin_date,
         end: optional_date(binding, "endToken"),
         geom: geom,
         location_source: location_source,
         wiki_url_fr: wiki_url_fr,
         wiki_url_en: wiki_url_en,
         sitelink_count: sitelink_count(binding)
       }}
    else
      :error -> :error
    end
  end

  defp extract_qid(binding) do
    with {:ok, uri} <- fetch_value(binding, "e"),
         [_, qid] <- run_regex(@qid_uri_regex, uri) do
      {:ok, qid}
    else
      _ -> :error
    end
  end

  # Splits a `time|precision|calendar` token (see moduledoc) back into its
  # parts. A token with the wrong arity (an unexpected shape from the
  # endpoint) rejects the binding, exactly like a missing date.
  defp extract_date(binding, token_key) do
    with {:ok, token} <- fetch_value(binding, token_key),
         [time, precision_str, calendar] <- split_token(token),
         {:ok, precision} <- parse_integer(precision_str),
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

  defp split_token(token) when is_binary(token), do: String.split(token, "|")
  defp split_token(_token), do: :error

  defp optional_date(binding, token_key) do
    case extract_date(binding, token_key) do
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

  # An absent article URL is fine (most events have no article in one of
  # the two languages); a present but invalid one (not https, not a
  # Wikimedia host, longer than the accepted bound) rejects the binding:
  # see `Amanogawa.WikimediaUrl`.
  defp extract_wiki_url(binding, key) do
    case fetch_value(binding, key) do
      {:ok, url} -> if WikimediaUrl.valid?(url), do: {:ok, url}, else: :error
      :error -> {:ok, nil}
    end
  end

  defp extract_kind(binding) do
    case fetch_value(binding, "kind") do
      {:ok, uri} ->
        case run_regex(@qid_uri_regex, uri) do
          [_, qid] -> qid
          nil -> nil
        end

      :error ->
        nil
    end
  end

  defp bounded_text(binding, key) do
    case fetch_value(binding, key) do
      {:ok, value} when is_binary(value) -> truncate(value)
      _ -> nil
    end
  end

  defp truncate(value) do
    if String.length(value) > @max_text_length do
      String.slice(value, 0, @max_text_length)
    else
      value
    end
  end

  defp sitelink_count(binding) do
    with {:ok, value} <- fetch_value(binding, "sitelinkCount"),
         {:ok, count} <- parse_integer(value) do
      count |> max(0) |> min(@max_sitelink_count)
    else
      _ -> 0
    end
  end

  defp fetch_value(binding, key) do
    case Map.fetch(binding, key) do
      {:ok, %{value: value}} -> {:ok, value}
      :error -> :error
    end
  end

  defp parse_integer(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_integer(_str), do: :error

  defp run_regex(regex, value) when is_binary(value), do: Regex.run(regex, value)
  defp run_regex(_regex, _value), do: nil

  # WKT longitude comes first, latitude second (`POINT(lon lat)`): the
  # opposite order of the (lat, lon) most humans expect, and the single
  # detail most likely to be silently transposed by a careless rewrite.
  # Case-insensitive: GeoSPARQL serializers emit both `POINT(...)` and
  # `Point(...)`.
  defp parse_wkt_point(wkt) when is_binary(wkt) do
    with [_, lon_str, lat_str] <- Regex.run(@wkt_point_regex, wkt),
         {:ok, lon} <- parse_coordinate(lon_str, -180.0, 180.0),
         {:ok, lat} <- parse_coordinate(lat_str, -90.0, 90.0) do
      {:ok, %Geo.Point{coordinates: {lon, lat}, srid: 4326}}
    else
      _ -> :error
    end
  end

  defp parse_wkt_point(_), do: :error

  # A partial parse (or any other surprise from `Float.parse/1`) rejects
  # the coordinate instead of crashing the page: the regex bounds above
  # guarantee no overflow, this clause guarantees no crash regardless.
  defp parse_coordinate(str, min, max) do
    case Float.parse(str) do
      {float, ""} when float >= min and float <= max -> {:ok, float}
      _ -> :error
    end
  end
end
