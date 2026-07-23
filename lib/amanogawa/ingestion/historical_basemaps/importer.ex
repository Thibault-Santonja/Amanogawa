defmodule Amanogawa.Ingestion.HistoricalBasemaps.Importer do
  @moduledoc """
  Entry point of the historical-basemaps import (issue #024): discovers
  the tranche files in a directory, maps their filenames to years
  (`Amanogawa.Ingestion.HistoricalBasemaps.Parser.parse_filename_year/1`),
  keeps only the ones strictly before the Cliopatria junction
  (`Amanogawa.Ingestion.HistoricalBasemaps.Parser.slice_intervals/1`), and
  imports all of them into `atlas.borders` under one `source` in a single
  purge-then-reinsert transaction (`Amanogawa.Atlas.replace_borders/2`):
  every tranche's features are lazily concatenated
  (`Amanogawa.Ingestion.Borders.Importer.stream_rows/3` +
  `Stream.concat/1`) before that single call, so an earlier tranche's rows
  are never wiped by a later tranche's own import (unlike calling
  `Amanogawa.Ingestion.Borders.Importer.import/3` once per file would).

  Called by `Mix.Tasks.Amanogawa.Import.HistoricalBasemaps`.
  """

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.Borders.Importer
  alias Amanogawa.Ingestion.HistoricalBasemaps.Parser

  @source "historical_basemaps"

  @type summary :: %{
          purged: non_neg_integer(),
          total: non_neg_integer(),
          repaired: non_neg_integer(),
          inserted: non_neg_integer(),
          rejected_empty: non_neg_integer(),
          skipped: non_neg_integer(),
          invalid_features: non_neg_integer(),
          tranches_imported: [integer()],
          tranches_excluded: [integer()],
          unrecognized_files: [String.t()]
        }

  @doc "The `atlas.polities`/`atlas.borders` source tag used for every historical-basemaps row."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  Imports every `*.geojson` file directly under `dir_path` whose name
  matches historical-basemaps' `world[_bc]<year>.geojson` convention and
  whose year is strictly before -3400. Files matching neither condition
  are reported (`:unrecognized_files` for a name the pattern does not
  match at all, `:tranches_excluded` for a recognized year `>= -3400`),
  never raised.
  """
  @spec import(Path.t()) :: {:ok, summary()}
  def import(dir_path) do
    {recognized, unrecognized_files} =
      dir_path |> discover_geojson_files() |> classify_filenames()

    slice_by_year =
      recognized
      |> Enum.map(fn {_path, _filename, year} -> year end)
      |> Parser.slice_intervals()
      |> Map.new(&{&1.year, &1})

    {included, excluded} =
      Enum.split_with(recognized, fn {_path, _filename, year} ->
        Map.has_key?(slice_by_year, year)
      end)

    {rows_streams, counters_list} =
      included
      |> Enum.map(fn {path, _filename, year} ->
        Importer.stream_rows(path, @source, wrap_parser(Map.fetch!(slice_by_year, year)))
      end)
      |> Enum.unzip()

    {:ok, border_stats} = Atlas.replace_borders(@source, Stream.concat(rows_streams))

    {:ok,
     border_stats
     |> Map.merge(merge_counters(counters_list))
     |> Map.put(:tranches_imported, sorted_years(included))
     |> Map.put(:tranches_excluded, sorted_years(excluded))
     |> Map.put(:unrecognized_files, unrecognized_files)}
  end

  defp discover_geojson_files(dir_path) do
    dir_path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".geojson"))
    |> Enum.sort()
    |> Enum.map(&Path.join(dir_path, &1))
  end

  defp classify_filenames(paths) do
    {recognized, unrecognized} =
      Enum.reduce(paths, {[], []}, fn path, {recognized, unrecognized} ->
        filename = Path.basename(path)

        case Parser.parse_filename_year(filename) do
          {:ok, year} -> {[{path, filename, year} | recognized], unrecognized}
          {:error, _reason} -> {recognized, [filename | unrecognized]}
        end
      end)

    {Enum.reverse(recognized), Enum.reverse(unrecognized)}
  end

  defp wrap_parser(slice) do
    fn feature ->
      case Parser.parse_feature(feature) do
        {:ok, attrs} ->
          {:ok, Map.merge(attrs, %{from_year: slice.from_year, to_year: slice.to_year})}

        other ->
          other
      end
    end
  end

  defp merge_counters(counters_list) do
    Enum.reduce(counters_list, %{skipped: 0, invalid_features: 0}, fn counters, acc ->
      Map.merge(acc, Importer.counters_summary(counters), fn _key, a, b -> a + b end)
    end)
  end

  defp sorted_years(entries),
    do: entries |> Enum.map(fn {_path, _filename, year} -> year end) |> Enum.sort()
end
