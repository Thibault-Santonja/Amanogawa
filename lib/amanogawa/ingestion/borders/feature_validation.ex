defmodule Amanogawa.Ingestion.Borders.FeatureValidation do
  @moduledoc """
  Per-feature validation shared by `Amanogawa.Ingestion.Cliopatria.Parser`
  and `Amanogawa.Ingestion.HistoricalBasemaps.Parser` (F05 security/quality
  reviews): both sources are external, hand-digitized datasets, so every
  value a feature carries is validated here before it may reach the SQL
  pipeline (`Amanogawa.Atlas.BorderQueries.insert_batch/3`), where a bad
  value would otherwise abort a whole batch's transaction (or worse, an
  overflowing year would abort the statement with an int4 range error).
  Every rejection is a tagged `{:error, ...}`, counted as one
  `invalid_features` by `Amanogawa.Ingestion.Borders.Importer`, never
  fatal to the run.

  ## Bounds

    * Years: `atlas.borders.from_year`/`to_year` are PostgreSQL `integer`
      (int4, `[-2_147_483_648, 2_147_483_647]`); beyond that hard limit,
      any year outside `[#{-200_000}, #{3000}]` is rejected as implausible
      for these datasets (historical-basemaps' oldest tranche is
      -123_000, Cliopatria ends at 2024; a value outside the plausibility
      window is a data error, not a legitimate outlier).
    * Names: at most #{500} characters. A longer one is rejected (not
      truncated: `(name, source)` is `atlas.polities`' natural key, and
      truncation could silently merge two distinct entities), mirroring
      `Amanogawa.Atlas.Polity.changeset/2`'s own `validate_length`.
    * Precision: an integer in `#{inspect(0..10)}` is kept; anything else
      (a string, a float, an out-of-range integer) degrades to `nil`
      (precision is an optional display hint, never worth rejecting an
      otherwise valid feature over).
    * Geometry: `Polygon`/`MultiPolygon` only, with structurally valid
      `coordinates` (non-empty nesting per type, every position a list of
      2 or 3 finite numbers, longitude in `[-180, 180]`, latitude in
      `[-90, 90]`). Geometric validity (self-intersections, ring closure)
      stays PostGIS's job (`ST_MakeValid`); this is the structural guard
      that keeps garbage out of `ST_GeomFromGeoJSON`.
  """

  @min_year -200_000
  @max_year 3000
  @max_name_length 500
  @precision_range 0..10

  @doc "The plausibility window years must fall in, `{min, max}`."
  @spec year_bounds() :: {integer(), integer()}
  def year_bounds, do: {@min_year, @max_year}

  @doc "Maximum accepted `name` length, in characters."
  @spec max_name_length() :: pos_integer()
  def max_name_length, do: @max_name_length

  @doc """
  Validates a year already known to be an integer: `{:ok, year}` inside
  the plausibility window, `{:error, {:year_out_of_bounds, key, year}}`
  otherwise (`key` names the offending property in the source's own
  vocabulary, for a readable import log).
  """
  @spec validate_year_bounds(integer(), String.t()) ::
          {:ok, integer()} | {:error, {:year_out_of_bounds, String.t(), integer()}}
  def validate_year_bounds(year, key) when is_integer(year) do
    if year >= @min_year and year <= @max_year do
      {:ok, year}
    else
      {:error, {:year_out_of_bounds, key, year}}
    end
  end

  @doc """
  Validates a name already known to be a non-empty binary:
  `{:error, {:name_too_long, length}}` beyond #{@max_name_length}
  characters (see the moduledoc for why rejection, not truncation).
  """
  @spec validate_name_length(String.t()) ::
          {:ok, String.t()} | {:error, {:name_too_long, non_neg_integer()}}
  def validate_name_length(name) when is_binary(name) do
    length = String.length(name)

    if length <= @max_name_length do
      {:ok, name}
    else
      {:error, {:name_too_long, length}}
    end
  end

  @doc """
  Degrades a raw precision value to `nil` unless it is an integer in
  `#{inspect(@precision_range)}` (see the moduledoc).
  """
  @spec normalize_precision(term()) :: integer() | nil
  def normalize_precision(precision) when is_integer(precision) and precision in @precision_range,
    do: precision

  def normalize_precision(_other), do: nil

  @doc """
  Structurally validates a GeoJSON `Polygon` or `MultiPolygon` geometry
  map (see the moduledoc for the exact contract). Any other shape,
  including `nil`, a missing/empty/mistyped `coordinates`, or an
  out-of-range position, is a tagged error.
  """
  @spec validate_geometry(term()) :: :ok | {:error, term()}
  def validate_geometry(%{"type" => "Polygon", "coordinates" => coordinates}) do
    validate_rings(coordinates)
  end

  def validate_geometry(%{"type" => "MultiPolygon", "coordinates" => coordinates}) do
    validate_non_empty_list(coordinates, &validate_rings/1)
  end

  def validate_geometry(_other), do: {:error, :invalid_geometry_type}

  defp validate_rings(rings), do: validate_non_empty_list(rings, &validate_ring/1)

  defp validate_ring(ring), do: validate_non_empty_list(ring, &validate_position/1)

  defp validate_non_empty_list([_ | _] = list, validate_element) do
    Enum.reduce_while(list, :ok, fn element, :ok ->
      case validate_element.(element) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_non_empty_list(_other, _validate_element),
    do: {:error, :invalid_geometry_coordinates}

  # A GeoJSON position: `[lon, lat]` or `[lon, lat, elevation]`, every
  # member a finite number, lon/lat within the WGS84 domain.
  defp validate_position([lon, lat]), do: validate_lon_lat(lon, lat)

  defp validate_position([lon, lat, elevation]) when is_number(elevation),
    do: validate_lon_lat(lon, lat)

  defp validate_position(_other), do: {:error, :invalid_geometry_coordinates}

  defp validate_lon_lat(lon, lat)
       when is_number(lon) and is_number(lat) and lon >= -180 and lon <= 180 and
              lat >= -90 and lat <= 90 do
    :ok
  end

  defp validate_lon_lat(_lon, _lat), do: {:error, :invalid_geometry_coordinates}
end
