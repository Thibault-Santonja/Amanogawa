defmodule AmanogawaWeb.Params.ExploreParams do
  @moduledoc """
  Parses and encodes the query parameters of the Explore page (`from`,
  `to`, `sel`, `z`, `lat`, `lng`) into the normalized state
  `AmanogawaWeb.ExploreLive` applies to its assigns (issue #018).

  `kinds` (a kind-of-event filter) was removed from this state (security
  review, dead-state finding): it was parsed, round-tripped and rendered
  into shareable URLs, but never actually applied to the events query
  (`AmanogawaWeb.Params.EventsQuery`/`Amanogawa.Atlas.EventQueries` never
  read it). A shared link carrying `kinds=...` would silently lie about
  filtering that never happened. Event-kind filtering is deferred to a
  future issue; when it lands, it must thread all the way to the SQL
  `where` clause before being reintroduced here.

  The URL is the single source of truth for shareable state
  (ADR 0005): `handle_params/3` is the only place that turns it into
  assigns, and this module is the only place that turns raw query params
  into validated values, or validated values back into a query.

  Year bounds mirror `AmanogawaWeb.Params.EventsQuery`, sharing the lower
  bound through `Amanogawa.HistoricalDate.min_year/0` so the two can never
  drift apart.

  Unlike `EventsQuery.parse/1`, `parse/1` here never fails: it powers page
  navigation, not an API contract, so a malformed or hostile query string
  must degrade to the default view rather than a 500
  (`.claude/rules/security.md`). Every field falls back to its own default
  independently; the one exception is the `from`/`to` pair, which is
  validated together (`from <= to`) and reset together, since a window
  where only one bound survived validation would silently mean something
  else.
  """

  alias Amanogawa.HistoricalDate
  alias AmanogawaWeb.Params.EventId

  @type t :: %{
          from: integer(),
          to: integer(),
          selected_qid: String.t() | nil,
          z: float(),
          lat: float(),
          lng: float()
        }

  @min_year HistoricalDate.min_year()

  # Minimum accepted width, in years, of a client-pushed time window
  # (issue #021's own default): mirrors, but is deliberately not shared
  # with, the JS drag gesture's own minimum
  # (`assets/js/hooks/timeline.js`'s `MIN_WINDOW_WIDTH_YEARS`), since the
  # two enforce the same rule against different domains (see
  # `valid_window?/2`'s own doc).
  @min_window_width_years 1

  # Mirrors the map hook's initial camera (`assets/js/hooks/map_hook.js`,
  # `INITIAL_CENTER`/`INITIAL_ZOOM`): kept in sync by hand, the two cannot
  # share a literal across the language boundary.
  @default_z 1.5
  @default_lat 20.0
  @default_lng 0.0

  @min_zoom 0
  @max_zoom 22
  @min_lat -90.0
  @max_lat 90.0
  @min_lng -180.0
  @max_lng 180.0

  @doc """
  Parses raw query params (string-keyed, as received in `handle_params/3`)
  into normalized Explore state. Always succeeds: an absent or invalid
  field falls back to its default.
  """
  @spec parse(map()) :: t()
  def parse(params) when is_map(params) do
    {from, to} = parse_window(params["from"], params["to"])

    %{
      from: from,
      to: to,
      selected_qid: parse_selected(params["sel"]),
      z: parse_zoom(params["z"]),
      lat: parse_coordinate(params["lat"], @min_lat, @max_lat, @default_lat),
      lng: parse_coordinate(params["lng"], @min_lng, @max_lng, @default_lng)
    }
  end

  @doc """
  True when `value` matches the Wikidata QID format (`Q` followed by
  digits, bounded length). Delegates to `AmanogawaWeb.Params.EventId`, the
  single definition shared with the events API endpoints (#016, #017).
  """
  @spec valid_qid?(term()) :: boolean()
  def valid_qid?(value), do: EventId.valid?(value)

  @doc """
  True when `z`/`lat`/`lng` are all within their valid ranges.

  Used by `AmanogawaWeb.ExploreLive` to validate a client-pushed
  `map_moved` payload: unlike `parse/1`, an invalid payload here must leave
  the current view unchanged rather than fall back to the page default, so
  the LiveView calls this guard directly instead of routing through
  `parse/1`.
  """
  @spec valid_view?(term(), term(), term()) :: boolean()
  def valid_view?(z, lat, lng) do
    is_number(z) and is_number(lat) and is_number(lng) and
      z >= @min_zoom and z <= @max_zoom and
      lat >= @min_lat and lat <= @max_lat and
      lng >= @min_lng and lng <= @max_lng
  end

  @doc """
  True when `from`/`to` are both integers within the domain (inclusive),
  strictly ordered, and at least `#{@min_window_width_years} an` apart
  (issue #021's own minimum window width). Used by
  `AmanogawaWeb.ExploreLive` to validate a client-pushed
  `select_time_window` payload, for the same "leave state unchanged on
  invalid input" reason as `valid_view?/3`: unlike `parse/1`, this never
  falls back to a default, a hostile or malformed payload is rejected
  outright, so the caller can distinguish "apply this window" from "ignore
  this request" and never partially applies one bound without the other.

  The domain here is the same one `parse/1` clamps a URL's `from`/`to`
  into (`Amanogawa.HistoricalDate`'s full astronomical range): wider than
  `Amanogawa.Atlas.TimeScale`'s own default rendering domain
  (`-300_000..2_100`), which only bounds what the timeline's symlog scale
  can *position on the strip* (`assets/js/lib/time_window.js`'s own
  header comment). A window this function accepts is always valid state
  to store and query by; whether the timeline hook's drag could have
  produced it unassisted is a separate, narrower question this function
  does not answer.

  ## Examples

      iex> AmanogawaWeb.Params.ExploreParams.valid_window?(-500, 500)
      true

      iex> AmanogawaWeb.Params.ExploreParams.valid_window?(500, -500)
      false

  """
  @spec valid_window?(term(), term()) :: boolean()
  def valid_window?(from, to) do
    is_integer(from) and is_integer(to) and
      from >= @min_year and from <= current_year() and
      to >= @min_year and to <= current_year() and
      to - from >= @min_window_width_years
  end

  @doc """
  Encodes Explore state back into query params, the inverse of `parse/1`.
  A field equal to its default is omitted, so the default view encodes to
  an empty map (a clean `/` URL rather than one padded with every default).

  ## Examples

      iex> AmanogawaWeb.Params.ExploreParams.to_query(%{
      ...>   from: -500,
      ...>   to: 500,
      ...>   selected_qid: nil,
      ...>   z: 1.5,
      ...>   lat: 20.0,
      ...>   lng: 0.0
      ...> })
      %{"from" => "-500", "to" => "500"}

  """
  @spec to_query(t()) :: %{String.t() => String.t()}
  def to_query(state) do
    %{}
    |> put_window(state)
    |> put_selected(state)
    |> put_view(state)
  end

  defp parse_window(from_param, to_param) do
    from = parse_year(from_param, @min_year)
    to = parse_year(to_param, current_year())

    if from <= to, do: {from, to}, else: {@min_year, current_year()}
  end

  defp parse_year(nil, default), do: default

  defp parse_year(value, default) do
    max_year = current_year()

    case parse_integer(value) do
      {:ok, year} when year >= @min_year and year <= max_year -> year
      _other -> default
    end
  end

  defp parse_selected(nil), do: nil
  defp parse_selected(value), do: if(valid_qid?(value), do: value, else: nil)

  defp parse_zoom(nil), do: @default_z

  defp parse_zoom(value) do
    case parse_number(value) do
      {:ok, z} when z >= @min_zoom and z <= @max_zoom -> z * 1.0
      _other -> @default_z
    end
  end

  defp parse_coordinate(nil, _min, _max, default), do: default

  defp parse_coordinate(value, min, max, default) do
    case parse_number(value) do
      {:ok, coordinate} when coordinate >= min and coordinate <= max -> coordinate * 1.0
      _other -> default
    end
  end

  defp parse_integer(value) when is_integer(value), do: {:ok, value}

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _other -> :error
    end
  end

  defp parse_integer(_other), do: :error

  defp parse_number(value) when is_number(value), do: {:ok, value}

  defp parse_number(value) when is_binary(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _other -> parse_integer(value)
    end
  end

  defp parse_number(_other), do: :error

  defp put_window(query, %{from: from, to: to}) do
    if {from, to} == {@min_year, current_year()} do
      query
    else
      query
      |> Map.put("from", Integer.to_string(from))
      |> Map.put("to", Integer.to_string(to))
    end
  end

  defp put_selected(query, %{selected_qid: nil}), do: query
  defp put_selected(query, %{selected_qid: qid}), do: Map.put(query, "sel", qid)

  defp put_view(query, %{z: z, lat: lat, lng: lng}) do
    if {z, lat, lng} == {@default_z, @default_lat, @default_lng} do
      query
    else
      query
      |> Map.put("z", to_string(z))
      |> Map.put("lat", to_string(lat))
      |> Map.put("lng", to_string(lng))
    end
  end

  defp current_year, do: Date.utc_today().year
end
