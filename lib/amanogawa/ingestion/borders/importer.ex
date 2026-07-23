defmodule Amanogawa.Ingestion.Borders.Importer do
  @moduledoc """
  Shared import engine reused by `Amanogawa.Ingestion.Cliopatria.Importer`
  (#023) and `Amanogawa.Ingestion.HistoricalBasemaps.Importer` (#024):
  streams a GeoJSON file (`Amanogawa.Ingestion.Borders.GeojsonStream`),
  applies a source-specific `parse_feature` function to each raw feature,
  resolves/creates the `Amanogawa.Atlas.Polity` for each feature's name
  (memoized for the run: a name seen twice never issues a second
  `Amanogawa.Atlas.upsert_polity/1` call), and replaces `source`'s borders
  (`Amanogawa.Atlas.replace_borders/2`) with the result. Every step is
  lazy, so memory stays bounded to one `Amanogawa.Atlas.BorderQueries`
  batch regardless of file size (#023's 307MB Cliopatria export).

  A polity's own `from_year`/`to_year` (`Amanogawa.Atlas.Polity`) is
  always left `nil` by this pipeline: neither Cliopatria nor
  historical-basemaps states an entity's overall existence span in a
  single place, only per-row/per-tranche dates
  (`Amanogawa.Atlas.Border.from_year`/`to_year`, the field every query in
  this project actually filters on, `.claude/memory/domain-model.md`:
  "frontières actives à l'année A"). Aggregating one from the stream would
  need either a second pass over the file or an unbounded in-memory
  min/max table; neither is worth it for a field nothing currently reads.

  ## Result shape

  `import/4` returns `{:ok, summary}`, merging `Amanogawa.Atlas.
  BorderQueries.batch_stats/0` (`:purged`, `:total`, `:repaired`,
  `:inserted`, `:rejected_empty`) with two counters specific to this
  layer:

    * `:skipped` - `parse_feature.(feature)` returned `:skip` (a
      well-formed feature that does not belong in `atlas.borders`, e.g.
      Cliopatria's non-`POLITY` rows).
    * `:invalid_features` - either `Amanogawa.Ingestion.Borders.
      GeojsonStream` itself yielded `{:error, {:invalid_json, _}}`, or
      `parse_feature.(feature)` returned `{:error, _}` (a required
      property missing or malformed).

  Neither counter ever raises or stops the run: a single malformed feature
  in a large import is logged and counted, never fatal
  (`.claude/rules/elixir-idioms.md`: "changesets validate at the boundary",
  the boundary here being one feature, not the whole file).
  """

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.Borders.GeojsonStream

  @type row_attrs :: %{
          name: String.t(),
          geometry: map(),
          precision: integer() | nil,
          from_year: integer(),
          to_year: integer()
        }
  @type parse_result :: {:ok, row_attrs()} | :skip | {:error, term()}
  @type summary :: %{
          purged: non_neg_integer(),
          total: non_neg_integer(),
          repaired: non_neg_integer(),
          inserted: non_neg_integer(),
          rejected_empty: non_neg_integer(),
          skipped: non_neg_integer(),
          invalid_features: non_neg_integer()
        }

  @doc """
  Imports every feature of `path` into `atlas.borders` under `source`,
  replacing whatever was previously there for that source. Single-file
  convenience wrapper around `stream_rows/3` + `Amanogawa.Atlas.
  replace_borders/2`, used directly by `Amanogawa.Ingestion.Cliopatria.
  Importer` (one file). `Amanogawa.Ingestion.HistoricalBasemaps.Importer`
  (many tranche files sharing one source) composes `stream_rows/3` and
  `counters_summary/1` itself instead, so every tranche lands in the
  *same* purge-then-reinsert transaction rather than each file wiping the
  previous one's rows.

  `parse_feature`: a 1-arity function (`Amanogawa.Ingestion.Cliopatria.
  Parser.parse_feature/1` or `Amanogawa.Ingestion.HistoricalBasemaps.
  Parser.parse_feature/1`) turning one decoded GeoJSON feature into a
  `t:parse_result/0`. When the source needs per-tranche `from_year`/
  `to_year` not carried on the feature itself (historical-basemaps), the
  caller wraps its parser to inject them before handing it here.
  """
  @spec import(Path.t(), String.t(), (map() -> parse_result())) :: {:ok, summary()}
  def import(path, source, parse_feature)
      when is_binary(source) and is_function(parse_feature, 1) do
    {rows, counters} = stream_rows(path, source, parse_feature)
    {:ok, border_stats} = Atlas.replace_borders(source, rows)
    {:ok, Map.merge(border_stats, counters_summary(counters))}
  end

  @doc """
  Builds the lazy row stream for one file, without inserting anything:
  returns `{rows, counters_ref}`, `rows` an `Enumerable.t()` of
  `Amanogawa.Atlas.BorderQueries.raw_row/0`-shaped maps (minus `:id`),
  `counters_ref` an `:counters` reference that only holds meaningful
  values once `rows` has actually been enumerated (`counters_summary/1`
  reads it afterwards). Exposed so a caller needing several files under
  one `source` (`Amanogawa.Ingestion.HistoricalBasemaps.Importer`) can
  `Stream.concat/1` several of these before the single `Amanogawa.Atlas.
  replace_borders/2` call that actually drives them.
  """
  @spec stream_rows(Path.t(), String.t(), (map() -> parse_result())) ::
          {Enumerable.t(), :counters.counters_ref()}
  def stream_rows(path, source, parse_feature) do
    counters = :counters.new(2, [])

    rows =
      path
      |> GeojsonStream.features()
      |> Stream.transform(%{}, &process_feature(&1, &2, source, parse_feature, counters))

    {rows, counters}
  end

  @doc "Reads a `stream_rows/3` counters reference into `%{skipped:, invalid_features:}`."
  @spec counters_summary(:counters.counters_ref()) :: %{
          skipped: non_neg_integer(),
          invalid_features: non_neg_integer()
        }
  def counters_summary(counters) do
    %{skipped: :counters.get(counters, 1), invalid_features: :counters.get(counters, 2)}
  end

  defp process_feature(
         {:error, {:invalid_json, _reason}},
         cache,
         _source,
         _parse_feature,
         counters
       ) do
    :counters.add(counters, 2, 1)
    {[], cache}
  end

  defp process_feature({:ok, feature}, cache, source, parse_feature, counters) do
    case parse_feature.(feature) do
      {:ok, attrs} ->
        {polity_id, cache} = resolve_polity_id(cache, attrs.name, source)
        {[build_row(polity_id, attrs, source)], cache}

      :skip ->
        :counters.add(counters, 1, 1)
        {[], cache}

      {:error, _reason} ->
        :counters.add(counters, 2, 1)
        {[], cache}
    end
  end

  defp resolve_polity_id(cache, name, source) do
    case Map.fetch(cache, name) do
      {:ok, id} ->
        {id, cache}

      :error ->
        {:ok, polity} = Atlas.upsert_polity(%{name: name, source: source})
        {polity.id, Map.put(cache, name, polity.id)}
    end
  end

  defp build_row(polity_id, attrs, source) do
    %{
      polity_id: polity_id,
      geometry: attrs.geometry,
      from_year: attrs.from_year,
      to_year: attrs.to_year,
      source: source,
      precision: Map.get(attrs, :precision)
    }
  end
end
