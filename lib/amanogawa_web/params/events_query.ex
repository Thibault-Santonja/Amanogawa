defmodule AmanogawaWeb.Params.EventsQuery do
  @moduledoc """
  Parses and validates the raw query parameters of `GET /api/events`
  (`bbox`, `from`, `to`, `limit`) into the normalized options expected by
  `Amanogawa.Atlas.list_events_geojson/1`.

  Every bound is enforced here, server-side, per `.claude/rules/
  security.md`: a caller can never widen the world, extend the time window
  past the supported range, or request an unbounded number of results. A
  malformed parameter always yields `{:error, errors}`, never an exception.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type envelope :: %{min_lon: float(), min_lat: float(), max_lon: float(), max_lat: float()}
  @type normalized :: %{
          envelopes: [envelope(), ...],
          from: integer(),
          to: integer(),
          limit: pos_integer()
        }

  # Age of the universe (Wikidata's deepest precision-0 dates), the lower
  # bound of every temporal query this project can legitimately serve.
  @min_year -13_800_000_000

  @default_limit 500
  @max_limit 2000

  @world [%{min_lon: -180.0, min_lat: -90.0, max_lon: 180.0, max_lat: 90.0}]

  @primary_key false
  embedded_schema do
    field :bbox, :string
    field :from, :integer
    field :to, :integer
    field :limit, :integer
  end

  @doc """
  Parses raw query params (string-keyed, as received in `conn.params`) into
  normalized options.

  Returns `{:ok, normalized}` or `{:error, errors}`, `errors` being
  `%{field => [message]}`.
  """
  @spec parse(map()) :: {:ok, normalized()} | {:error, %{atom() => [String.t()]}}
  def parse(params) when is_map(params) do
    changeset = changeset(params)

    if changeset.valid? do
      {:ok, normalize(changeset)}
    else
      {:error, errors(changeset)}
    end
  end

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:bbox, :from, :to, :limit])
    |> validate_bbox()
    |> validate_year(:from)
    |> validate_year(:to)
    |> validate_from_before_to()
    |> validate_limit()
  end

  @doc """
  Parses a bbox query string `"min_lon,min_lat,max_lon,max_lat"` into one
  or two envelopes ready for `ST_MakeEnvelope`.

  A bbox crossing the antimeridian (`min_lon > max_lon`) is decomposed into
  two envelopes, `[min_lon, 180]` and `[-180, max_lon]`, rather than one:
  the caller never has to special-case the antimeridian downstream.

  ## Examples

      iex> AmanogawaWeb.Params.EventsQuery.parse_bbox("2.0,48.0,3.0,49.0")
      {:ok, [%{min_lon: 2.0, min_lat: 48.0, max_lon: 3.0, max_lat: 49.0}]}

      iex> AmanogawaWeb.Params.EventsQuery.parse_bbox("170,-10,-170,10")
      {:ok,
       [
         %{min_lon: 170.0, min_lat: -10.0, max_lon: 180.0, max_lat: 10.0},
         %{min_lon: -180.0, min_lat: -10.0, max_lon: -170.0, max_lat: 10.0}
       ]}

  """
  @spec parse_bbox(String.t()) :: {:ok, [envelope(), ...]} | {:error, String.t()}
  def parse_bbox(bbox_string) when is_binary(bbox_string) do
    with {:ok, [min_lon, min_lat, max_lon, max_lat]} <- parse_floats(bbox_string),
         :ok <- validate_lon(min_lon),
         :ok <- validate_lon(max_lon),
         :ok <- validate_lat(min_lat),
         :ok <- validate_lat(max_lat),
         :ok <- validate_lat_order(min_lat, max_lat) do
      {:ok, envelopes(min_lon, min_lat, max_lon, max_lat)}
    end
  end

  defp parse_floats(bbox_string) do
    case bbox_string |> String.split(",") |> Enum.map(&String.trim/1) do
      [_, _, _, _] = parts ->
        parse_all_floats(parts)

      _other ->
        {:error, "bbox must be 4 comma-separated numbers: min_lon,min_lat,max_lon,max_lat"}
    end
  end

  defp parse_all_floats(parts) do
    case Enum.map(parts, &Float.parse/1) do
      [{min_lon, ""}, {min_lat, ""}, {max_lon, ""}, {max_lat, ""}] ->
        {:ok, [min_lon, min_lat, max_lon, max_lat]}

      _other ->
        {:error, "bbox must be 4 comma-separated numbers: min_lon,min_lat,max_lon,max_lat"}
    end
  end

  defp validate_lon(lon) when lon >= -180.0 and lon <= 180.0, do: :ok
  defp validate_lon(_lon), do: {:error, "longitude must be within [-180, 180]"}

  defp validate_lat(lat) when lat >= -90.0 and lat <= 90.0, do: :ok
  defp validate_lat(_lat), do: {:error, "latitude must be within [-90, 90]"}

  defp validate_lat_order(min_lat, max_lat) when min_lat < max_lat, do: :ok
  defp validate_lat_order(_min_lat, _max_lat), do: {:error, "min_lat must be less than max_lat"}

  defp envelopes(min_lon, min_lat, max_lon, max_lat) when min_lon > max_lon do
    [
      %{min_lon: min_lon, min_lat: min_lat, max_lon: 180.0, max_lat: max_lat},
      %{min_lon: -180.0, min_lat: min_lat, max_lon: max_lon, max_lat: max_lat}
    ]
  end

  defp envelopes(min_lon, min_lat, max_lon, max_lat) do
    [%{min_lon: min_lon, min_lat: min_lat, max_lon: max_lon, max_lat: max_lat}]
  end

  defp validate_bbox(changeset) do
    validate_change(changeset, :bbox, fn :bbox, bbox_string ->
      case parse_bbox(bbox_string) do
        {:ok, _envelopes} -> []
        {:error, message} -> [bbox: message]
      end
    end)
  end

  defp validate_year(changeset, field) do
    validate_number(changeset, field,
      greater_than_or_equal_to: @min_year,
      less_than_or_equal_to: current_year()
    )
  end

  defp validate_from_before_to(changeset) do
    case {get_field(changeset, :from), get_field(changeset, :to)} do
      {from, to} when is_integer(from) and is_integer(to) and from > to ->
        add_error(changeset, :from, "must be less than or equal to to")

      _other ->
        changeset
    end
  end

  defp validate_limit(changeset) do
    case get_field(changeset, :limit) do
      nil -> changeset
      limit when limit <= 0 -> add_error(changeset, :limit, "must be a positive integer")
      _limit -> changeset
    end
  end

  defp normalize(changeset) do
    %{
      envelopes: bbox_envelopes(changeset),
      from: get_field(changeset, :from) || @min_year,
      to: get_field(changeset, :to) || current_year(),
      limit: clamp_limit(get_field(changeset, :limit))
    }
  end

  defp bbox_envelopes(changeset) do
    case get_field(changeset, :bbox) do
      nil ->
        @world

      bbox_string ->
        {:ok, envelopes} = parse_bbox(bbox_string)
        envelopes
    end
  end

  defp clamp_limit(nil), do: @default_limit
  defp clamp_limit(limit) when limit > @max_limit, do: @max_limit
  defp clamp_limit(limit), do: limit

  defp current_year, do: Date.utc_today().year

  defp errors(changeset) do
    traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
