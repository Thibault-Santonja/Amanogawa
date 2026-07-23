defmodule Amanogawa.Ingestion.Cliopatria.Parser do
  @moduledoc """
  Maps one raw Cliopatria GeoJSON feature (as decoded by
  `Amanogawa.Ingestion.Borders.GeojsonStream`) to a row ready for
  `Amanogawa.Ingestion.Borders.Importer`.

  Cliopatria's documented columns (Seshat-Global-History-Databank/
  cliopatria README, `.claude/memory/data-sources.md`): `Name`, `FromYear`,
  `ToYear` (signed astronomical years, `.claude/rules/geo-temporal.md`),
  `Type` (`POLITY` for a territory polygon, `RELATION` for a
  non-territorial link between two entities). Only `POLITY` rows describe
  a zone of influence this project renders as a border; every other `Type`
  is `:skip`, not an error: a well-formed row of a kind this pipeline does
  not use is not malformed data. A feature with no `Type` property at all
  is treated as `POLITY` (lenient default, matching every real sample seen
  in the dataset's own documentation).

  Every per-feature value is validated before it may reach the SQL
  pipeline (`Amanogawa.Ingestion.Borders.FeatureValidation`: years inside
  the plausibility window and the int4 domain, `Name` at most 500
  characters, structurally valid `Polygon`/`MultiPolygon` coordinates).
  Any deviation is a tagged `{:error, ...}` counted as one
  `invalid_features` by the importer, never fatal to the run.

  `precision` is always `nil` for Cliopatria: unlike historical-basemaps'
  `BORDERPRECISION` (#024), Cliopatria carries no coarseness marker.

  ## Examples

      iex> feature = %{
      ...>   "properties" => %{"Name" => "Roman Empire", "FromYear" => -27, "ToYear" => 395, "Type" => "POLITY"},
      ...>   "geometry" => %{"type" => "Polygon", "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]}
      ...> }
      iex> Amanogawa.Ingestion.Cliopatria.Parser.parse_feature(feature)
      {:ok, %{name: "Roman Empire", from_year: -27, to_year: 395, geometry: %{"type" => "Polygon", "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]}, precision: nil}}

      iex> feature = %{"properties" => %{"Name" => "A relation", "Type" => "RELATION"}, "geometry" => nil}
      iex> Amanogawa.Ingestion.Cliopatria.Parser.parse_feature(feature)
      :skip

  """

  alias Amanogawa.Ingestion.Borders.FeatureValidation

  @type parse_result :: {:ok, map()} | :skip | {:error, term()}

  @doc "Parses one decoded GeoJSON feature. See the moduledoc for the return contract."
  @spec parse_feature(map()) :: parse_result()
  def parse_feature(%{"properties" => properties, "geometry" => geometry})
      when is_map(properties) do
    with :ok <- check_polity_type(properties),
         {:ok, name} <- fetch_name(properties),
         {:ok, from_year} <- fetch_year(properties, "FromYear"),
         {:ok, to_year} <- fetch_year(properties, "ToYear"),
         :ok <- validate_year_order(from_year, to_year),
         :ok <- FeatureValidation.validate_geometry(geometry) do
      {:ok,
       %{name: name, from_year: from_year, to_year: to_year, geometry: geometry, precision: nil}}
    end
  end

  def parse_feature(_other), do: {:error, :missing_properties_or_geometry}

  defp check_polity_type(%{"Type" => type}) when type not in ["POLITY", nil], do: :skip
  defp check_polity_type(_properties), do: :ok

  defp fetch_name(properties) do
    case Map.get(properties, "Name") do
      name when is_binary(name) and name != "" ->
        FeatureValidation.validate_name_length(name)

      _other ->
        {:error, {:missing_or_invalid_property, "Name"}}
    end
  end

  # Cliopatria documents years as integers; a whole-valued float is
  # normalized rather than rejected (issue #023: "vérifier ... que les
  # années sont bien des entiers signés ... et normaliser sinon"), a
  # non-whole float or any other type is a genuine error. Either way the
  # resulting integer must fall in `FeatureValidation.year_bounds/0`
  # (which also keeps it inside the int4 column domain).
  defp fetch_year(properties, key) do
    case Map.get(properties, key) do
      year when is_integer(year) ->
        FeatureValidation.validate_year_bounds(year, key)

      year when is_float(year) ->
        normalize_whole_year(year, key)

      _other ->
        {:error, {:missing_or_invalid_property, key}}
    end
  end

  defp normalize_whole_year(year, key) when year == trunc(year) * 1.0,
    do: FeatureValidation.validate_year_bounds(trunc(year), key)

  defp normalize_whole_year(_year, key), do: {:error, {:missing_or_invalid_property, key}}

  # `atlas.borders`' own check constraint (`from_year_before_or_equal_to_year`)
  # would otherwise reject this row deep in a bulk `INSERT` inside
  # `Amanogawa.Atlas.BorderQueries.insert_batch/3`, aborting the whole
  # batch's transaction for one bad row; caught here instead, as a tagged
  # error like every other malformed property.
  defp validate_year_order(from_year, to_year) when from_year <= to_year, do: :ok

  defp validate_year_order(from_year, to_year),
    do: {:error, {:invalid_year_range, from_year, to_year}}
end
