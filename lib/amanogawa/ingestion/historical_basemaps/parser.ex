defmodule Amanogawa.Ingestion.HistoricalBasemaps.Parser do
  @moduledoc """
  Maps historical-basemaps (aourednik/historical-basemaps, GPL-3.0) data to
  rows for `Amanogawa.Ingestion.Borders.Importer` (issue #024).

  Each source file is a single-year snapshot (`world_bc4000.geojson`, one
  `FeatureCollection` per tranche), not a dated range like Cliopatria: this
  module's `parse_feature/1` extracts only the per-feature attributes
  (`NAME`, `BORDERPRECISION`); `slice_intervals/1` and
  `parse_filename_year/1` turn the set of tranche filenames present in a
  directory into `from_year`/`to_year` pairs, applied uniformly to every
  feature of a given tranche by the caller (`Amanogawa.Ingestion.
  HistoricalBasemaps.Importer`).

  ## Junction with Cliopatria (ADR 0004, issue #023)

  historical-basemaps serves years strictly before -3400 only: Cliopatria
  is the exclusive source at and after -3400. `slice_intervals/1` enforces
  this at both ends: a tranche `>= -3400` is filtered out entirely, and the
  chronologically last used tranche is always bounded to `to_year: -3401`,
  regardless of how far that tranche's own filename year is from -3400,
  so the two sources' year ranges never overlap.
  """

  @junction_year -3_400
  @last_to_year -3_401

  @type slice :: %{year: integer(), from_year: integer(), to_year: integer()}
  @type parse_result :: {:ok, map()} | :skip | {:error, term()}

  @doc """
  Parses one decoded GeoJSON feature: `NAME` becomes `:name`,
  `BORDERPRECISION` becomes `:precision` (`nil` when absent). A feature
  with no `NAME` (or an empty one) is `:skip`, not an error (issue #024:
  "tolérer les features sans nom ... les écarter"): historical-basemaps
  carries some unnamed geographic features that are not political entities.

  ## Examples

      iex> feature = %{"properties" => %{"NAME" => "Roman Empire", "BORDERPRECISION" => 2}, "geometry" => %{"type" => "Polygon", "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]}}
      iex> Amanogawa.Ingestion.HistoricalBasemaps.Parser.parse_feature(feature)
      {:ok, %{name: "Roman Empire", geometry: %{"type" => "Polygon", "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]}, precision: 2}}

  """
  @spec parse_feature(map()) :: parse_result()
  def parse_feature(%{"properties" => properties, "geometry" => geometry})
      when is_map(properties) do
    case Map.get(properties, "NAME") do
      name when is_binary(name) and name != "" ->
        with :ok <- validate_geometry(geometry) do
          {:ok,
           %{name: name, geometry: geometry, precision: Map.get(properties, "BORDERPRECISION")}}
        end

      _other ->
        :skip
    end
  end

  def parse_feature(_other), do: {:error, :missing_properties_or_geometry}

  @doc """
  Parses a historical-basemaps filename into its snapshot year: `world_bc
  <N>.geojson` is astronomical year `-N` (BCE tranches, the only ones this
  project imports), `world_<N>.geojson` is year `N` (CE tranches, always
  excluded downstream by `slice_intervals/1` since none is `< -3400`, kept
  recognized here rather than misfiled as an unrecognized name). Any other
  name is a tagged error (issue #024's error case), never a crash: one
  oddly named file must not abort a whole directory import.

  ## Examples

      iex> Amanogawa.Ingestion.HistoricalBasemaps.Parser.parse_filename_year("world_bc4000.geojson")
      {:ok, -4000}

      iex> Amanogawa.Ingestion.HistoricalBasemaps.Parser.parse_filename_year("world_1000.geojson")
      {:ok, 1000}

      iex> Amanogawa.Ingestion.HistoricalBasemaps.Parser.parse_filename_year("places.geojson")
      {:error, {:unrecognized_filename, "places.geojson"}}

  """
  @spec parse_filename_year(String.t()) ::
          {:ok, integer()} | {:error, {:unrecognized_filename, String.t()}}
  def parse_filename_year(filename) do
    case Regex.run(~r/^world_bc(\d+)\.geojson$/, filename) do
      [_, digits] ->
        {:ok, -String.to_integer(digits)}

      nil ->
        case Regex.run(~r/^world_(\d+)\.geojson$/, filename) do
          [_, digits] -> {:ok, String.to_integer(digits)}
          nil -> {:error, {:unrecognized_filename, filename}}
        end
    end
  end

  @doc """
  Maps a list of tranche years to contiguous, non-overlapping
  `from_year`/`to_year` intervals (issue #024): years `>= #{@junction_year}`
  are dropped (Cliopatria's exclusive territory); for the remaining
  years sorted ascending `a1 < a2 < ... < an`, `from_year = ai` and
  `to_year = a(i+1) - 1`, except the last (largest) one, always bounded to
  `to_year: #{@last_to_year}` regardless of how close its own year is to
  the junction, so the covered range always ends exactly where Cliopatria's
  begins.

  ## Examples

      iex> Amanogawa.Ingestion.HistoricalBasemaps.Parser.slice_intervals([-123_000, -10_000, -8_000, -5_000, -4_000])
      [
        %{year: -123_000, from_year: -123_000, to_year: -10_001},
        %{year: -10_000, from_year: -10_000, to_year: -8_001},
        %{year: -8_000, from_year: -8_000, to_year: -5_001},
        %{year: -5_000, from_year: -5_000, to_year: -4_001},
        %{year: -4_000, from_year: -4_000, to_year: -3_401}
      ]

  """
  @spec slice_intervals([integer()]) :: [slice()]
  def slice_intervals(years) do
    years
    |> Enum.filter(&(&1 < @junction_year))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.chunk_every(2, 1, [:none])
    |> Enum.map(&to_interval/1)
  end

  defp to_interval([year, :none]), do: %{year: year, from_year: year, to_year: @last_to_year}
  defp to_interval([year, next_year]), do: %{year: year, from_year: year, to_year: next_year - 1}

  defp validate_geometry(%{"type" => type}) when type in ["Polygon", "MultiPolygon"], do: :ok
  defp validate_geometry(_other), do: {:error, :invalid_geometry_type}
end
