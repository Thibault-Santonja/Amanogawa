defmodule Amanogawa.Ingestion.Wikidata.Templates do
  @moduledoc """
  Vetted SPARQL templates for the Wikidata event extraction (ADR 0003,
  `.claude/skills/wikidata-query/SKILL.md`).

  Every rendering function below builds its query from fixed strings owned
  by this module; the only variable points (QID range bounds, `LIMIT`,
  `OFFSET`, explicit QID lists) are substituted after strict validation
  (non-negative integers, `~r/^Q\\d+$/` QIDs). No caller-supplied string is
  ever concatenated into a query: passing anything else raises
  `ArgumentError` before a query is built, so no external data can alter a
  query's shape (`.claude/rules/security.md`).

  ## Query shape

  Every template selects from the `Q1190554` (occurrence) tree, excludes
  `Amanogawa.Ingestion.Wikidata.Blocklist.qids/0` with `MINUS` (QLever's
  SPARQL 1.1 support is partial: `FILTER NOT EXISTS` is avoided throughout,
  in favor of `MINUS`), and requires both a date and at least one
  coordinate (direct `P625`, or inherited from the place `P276 -> P625`):
  this is the "dated and geolocatable" corpus definition the project
  targets (~420 000 events, `.claude/memory/data-sources.md`).

  Date precision is read through `p:P585/psv:P585` (falling back to
  `p:P580/psv:P580`, the start time, when an event has no `P585` at all)
  and always includes `wikibase:timePrecision` and
  `wikibase:timeCalendarModel`: the `wdt:` property shortcut is never used
  for dates, since it silently drops the precision a display layer needs to
  avoid rendering a fake "January 1" (`.claude/rules/geo-temporal.md`).

  Every `OPTIONAL` variable is wrapped in `SAMPLE` under a `GROUP BY ?e`, so
  each query returns exactly one row per event regardless of how many
  optional patterns match (a place with several `P625` values, several
  `P585` statements as Wikidata's editors sometimes disagree on a date,
  ...).

  Labels and descriptions are read via `rdfs:label`/`schema:description`
  with an explicit `LANG()` filter rather than `SERVICE wikibase:label`,
  whose support on QLever is not guaranteed.
  """

  alias Amanogawa.Ingestion.Wikidata.Blocklist

  @qid_regex ~r/^Q\d+$/

  @prefixes """
  PREFIX wd: <http://www.wikidata.org/entity/>
  PREFIX wdt: <http://www.wikidata.org/prop/direct/>
  PREFIX p: <http://www.wikidata.org/prop/>
  PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
  PREFIX wikibase: <http://wikiba.se/ontology#>
  PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
  PREFIX schema: <http://schema.org/>
  PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>\
  """

  @select_vars """
  SELECT ?e
         (SAMPLE(?labelFrV) AS ?labelFr) (SAMPLE(?labelEnV) AS ?labelEn)
         (SAMPLE(?descFrV) AS ?descFr) (SAMPLE(?descEnV) AS ?descEn)
         (SAMPLE(?kindV) AS ?kind)
         (SAMPLE(?beginTimeRaw) AS ?beginTime) (SAMPLE(?beginPrecisionRaw) AS ?beginPrecision) (SAMPLE(?beginCalendarRaw) AS ?beginCalendar)
         (SAMPLE(?endTimeV) AS ?endTime) (SAMPLE(?endPrecisionV) AS ?endPrecision) (SAMPLE(?endCalendarV) AS ?endCalendar)
         (SAMPLE(?coordDirectV) AS ?coordDirect) (SAMPLE(?coordPlaceV) AS ?coordPlace)
         (SAMPLE(?articleFrV) AS ?articleFr) (SAMPLE(?articleEnV) AS ?articleEn)
         (SAMPLE(?sitelinkCountV) AS ?sitelinkCount)\
  """

  @root_pattern "?e wdt:P31/wdt:P279* wd:Q1190554 ."

  @date_pattern """
  {
      ?e p:P585/psv:P585 ?beginNode585 .
      ?beginNode585 wikibase:timeValue ?beginTimeRaw ;
                     wikibase:timePrecision ?beginPrecisionRaw ;
                     wikibase:timeCalendarModel ?beginCalendarRaw .
    }
    UNION
    {
      MINUS { ?e p:P585/psv:P585 ?anyBeginNode585 }
      ?e p:P580/psv:P580 ?beginNode580 .
      ?beginNode580 wikibase:timeValue ?beginTimeRaw ;
                     wikibase:timePrecision ?beginPrecisionRaw ;
                     wikibase:timeCalendarModel ?beginCalendarRaw .
    }\
  """

  @end_pattern """
  OPTIONAL {
      ?e p:P582/psv:P582 ?endNode .
      ?endNode wikibase:timeValue ?endTimeV ;
               wikibase:timePrecision ?endPrecisionV ;
               wikibase:timeCalendarModel ?endCalendarV .
    }\
  """

  @coordinate_pattern """
  OPTIONAL { ?e wdt:P625 ?coordDirectV . }
    OPTIONAL { ?e wdt:P276/wdt:P625 ?coordPlaceV . }
    FILTER(BOUND(?coordDirectV) || BOUND(?coordPlaceV))\
  """

  @meta_pattern """
  OPTIONAL { ?e rdfs:label ?labelFrV . FILTER(LANG(?labelFrV) = "fr") }
    OPTIONAL { ?e rdfs:label ?labelEnV . FILTER(LANG(?labelEnV) = "en") }
    OPTIONAL { ?e schema:description ?descFrV . FILTER(LANG(?descFrV) = "fr") }
    OPTIONAL { ?e schema:description ?descEnV . FILTER(LANG(?descEnV) = "en") }
    OPTIONAL { ?e wdt:P31 ?kindV . }
    OPTIONAL { ?articleFrV schema:about ?e ; schema:isPartOf <https://fr.wikipedia.org/> . }
    OPTIONAL { ?articleEnV schema:about ?e ; schema:isPartOf <https://en.wikipedia.org/> . }
    OPTIONAL { ?e wikibase:sitelinks ?sitelinkCountV . }\
  """

  @doc """
  Renders the paginated event extraction query for the numeric QID slice
  `[lower, upper)`, `limit`/`offset` rows within that slice.

  The slice is on the integer suffix of the entity's QID (`xsd:integer` of
  the part after `"Q"`), not on the IRI string: total, stable, and
  independent of any insertion happening elsewhere in Wikidata, which is
  what makes paging through it replayable and resumable (`Amanogawa.
  Ingestion.Workers.ImportEvents`'s cursor is exactly `{slice, offset}`).

  Raises `ArgumentError` when `lower`/`upper`/`limit`/`offset` are not
  non-negative integers (`limit` must additionally be positive), or when
  `upper` is not strictly greater than `lower`.

  ## Examples

      iex> query = Amanogawa.Ingestion.Wikidata.Templates.events_page(%{lower: 0, upper: 1000, limit: 10, offset: 0})
      iex> String.contains?(query, "wikibase:timePrecision")
      true

  """
  @spec events_page(%{
          lower: non_neg_integer(),
          upper: non_neg_integer(),
          limit: pos_integer(),
          offset: non_neg_integer()
        }) :: String.t()
  def events_page(%{lower: lower, upper: upper, limit: limit, offset: offset}) do
    validate_slice!(lower, upper)
    validate_positive_integer!(limit, :limit)
    validate_non_neg_integer!(offset, :offset)

    build_query(
      @select_vars,
      [
        @root_pattern,
        slice_filter(lower, upper),
        blocklist_minus(),
        @date_pattern,
        @end_pattern,
        @coordinate_pattern,
        @meta_pattern
      ],
      "GROUP BY ?e\nORDER BY ?e\nLIMIT #{limit}\nOFFSET #{offset}"
    )
  end

  @doc """
  Renders a query counting the events a slice `[lower, upper)` would yield,
  without paginating: used to calibrate slice sizes (`.claude/rules/
  wikidata-query` skill: aim for a few thousand bindings per page) before
  committing to a pagination plan.

  Raises `ArgumentError` under the same conditions as `events_page/1` (for
  the bounds it takes).

  ## Examples

      iex> query = Amanogawa.Ingestion.Wikidata.Templates.count_events(%{lower: 0, upper: 1000})
      iex> String.contains?(query, "COUNT")
      true

  """
  @spec count_events(%{lower: non_neg_integer(), upper: non_neg_integer()}) :: String.t()
  def count_events(%{lower: lower, upper: upper}) do
    validate_slice!(lower, upper)

    build_query(
      "SELECT (COUNT(DISTINCT ?e) AS ?count)",
      [
        @root_pattern,
        slice_filter(lower, upper),
        blocklist_minus(),
        @date_pattern,
        @coordinate_pattern
      ],
      nil
    )
  end

  @doc """
  Renders a query fetching specific events by QID, bypassing pagination:
  used to verify or re-fetch a known set of entities (regression fixtures,
  targeted spot checks) rather than a numeric slice.

  Raises `ArgumentError` when `qids` is empty or any entry does not match
  `~r/^Q\\d+$/`.

  ## Examples

      iex> query = Amanogawa.Ingestion.Wikidata.Templates.events_by_qids(["Q31900"])
      iex> String.contains?(query, "wd:Q31900")
      true

      iex> Amanogawa.Ingestion.Wikidata.Templates.events_by_qids(["not-a-qid"])
      ** (ArgumentError) invalid QID: "not-a-qid"

  """
  @spec events_by_qids([String.t()]) :: String.t()
  def events_by_qids(qids) when is_list(qids) do
    if qids == [], do: raise(ArgumentError, "qids must not be empty")
    Enum.each(qids, &validate_qid!/1)

    build_query(
      @select_vars,
      [
        values_clause(qids),
        blocklist_minus(),
        @date_pattern,
        @end_pattern,
        @coordinate_pattern,
        @meta_pattern
      ],
      "GROUP BY ?e"
    )
  end

  defp build_query(select_clause, where_fragments, tail) do
    where_body = where_fragments |> Enum.reject(&(&1 == "")) |> Enum.join("\n  ")

    [
      @prefixes,
      "",
      select_clause,
      "WHERE {",
      "  " <> where_body,
      "}",
      tail
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp slice_filter(lower, upper) do
    """
    BIND(xsd:integer(STRAFTER(STR(?e), "http://www.wikidata.org/entity/Q")) AS ?qidNum)
      FILTER(?qidNum >= #{lower} && ?qidNum < #{upper})\
    """
  end

  defp values_clause(qids) do
    values = Enum.map_join(qids, " ", &"wd:#{&1}")
    "VALUES ?e { #{values} }"
  end

  defp blocklist_minus do
    values = Enum.map_join(Blocklist.qids(), " ", &"wd:#{&1}")
    "MINUS { VALUES ?blocked { #{values} } ?e wdt:P31 ?blocked }"
  end

  defp validate_slice!(lower, upper) do
    validate_non_neg_integer!(lower, :lower)
    validate_non_neg_integer!(upper, :upper)

    if upper <= lower do
      raise ArgumentError, "upper (#{upper}) must be greater than lower (#{lower})"
    end
  end

  defp validate_non_neg_integer!(value, _name) when is_integer(value) and value >= 0, do: :ok

  defp validate_non_neg_integer!(value, name) do
    raise ArgumentError, "#{name} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp validate_positive_integer!(value, _name) when is_integer(value) and value > 0, do: :ok

  defp validate_positive_integer!(value, name) do
    raise ArgumentError, "#{name} must be a positive integer, got: #{inspect(value)}"
  end

  defp validate_qid!(qid) when is_binary(qid) do
    unless Regex.match?(@qid_regex, qid) do
      raise ArgumentError, "invalid QID: #{inspect(qid)}"
    end
  end

  defp validate_qid!(qid), do: raise(ArgumentError, "invalid QID: #{inspect(qid)}")
end
