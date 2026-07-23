defmodule AmanogawaWeb.Controllers.Api.EventController do
  @moduledoc """
  Read-only, rate-limited event endpoints
  (`AmanogawaWeb.Plugs.RateLimit` on the `:api` pipeline), all kept
  intentionally thin: parameter parsing and validation live in
  `AmanogawaWeb.Params`, every query in `Amanogawa.Atlas.EventQueries`,
  the GeoJSON/JSON shaping in `Amanogawa.Atlas`.

    * `GET /api/events?bbox=&from=&to=&limit=`: events for the map
      viewport and time window, ranked by importance, as a bounded
      GeoJSON `FeatureCollection` (issue #014, ADR 0007).
    * `GET /api/events/:qid/summary`: the hover card / event panel summary
      of a single event (issue #016).
    * `GET /api/events/:qid/links`: the typed relations of a single event,
      as a GeoJSON `FeatureCollection` of `LineString` features (issue
      #017).
    * `GET /api/events/histogram?from=&to=&buckets=`: the timeline density
      histogram (issue #020), aggregated in SQL by
      `Amanogawa.Atlas.event_histogram/1`.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.TimeScale
  alias AmanogawaWeb.Params.EventId
  alias AmanogawaWeb.Params.EventsQuery
  alias AmanogawaWeb.Params.HistogramQuery

  # Cache-Control max-age for the histogram response: short enough that a
  # stale response is never served for long (the corpus grows through
  # ingestion, not through user action, so a cached response only ever
  # under-counts by whatever synced in the last few minutes), long enough
  # to absorb a burst of near-identical requests from one client dragging
  # the timeline (`.claude/rules/liveview.md`'s 150ms debounce still lets
  # several requests through per drag).
  @histogram_cache_max_age_seconds 60

  # Fixed reference grid (issue #020, "Cache: ... + arrondi des bornes
  # demandées aux bords de buckets pour maximiser les hits") the histogram
  # endpoint snaps `from`/`to` to before querying: two requests whose
  # bounds differ by a few years but fall in the same grid cell converge on
  # the identical, cacheable window, rather than each producing its own
  # cache entry. Computed once at compile time from `TimeScale.default/0`
  # (200 points spanning the full domain in equal position steps, the
  # scale's own resolution, independent of the caller's requested
  # `buckets`): deliberately much coarser than the finest possible
  # `buckets` (200) so nearby requests actually collide instead of each
  # landing on its own grid cell.
  @cache_grid_size 40
  @cache_grid_edges (for i <- 0..@cache_grid_size do
                       TimeScale.year(TimeScale.default(), i / @cache_grid_size)
                     end)

  @doc """
  Renders the requested viewport as GeoJSON (`200`), or a structured
  validation error (`400`) when `bbox`, `from`, `to`, or `limit` is
  malformed.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    case EventsQuery.parse(params) do
      {:ok, opts} ->
        json(conn, Atlas.list_events_geojson(opts))

      {:error, errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: errors})
    end
  end

  @doc """
  Renders the summary of `qid` (`200`), `400` when `qid` fails
  `AmanogawaWeb.Params.EventId.valid?/1` (checked before any database
  access), `404` when `qid` is well-formed but unknown.
  """
  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, %{"qid" => qid}) do
    render_by_qid(conn, qid, &Atlas.get_event_summary/1)
  end

  @doc """
  Renders the typed relations of `qid` as a GeoJSON `FeatureCollection`
  (`200`, empty when the event has none), `400` for a malformed `qid`,
  `404` for an unknown one. Same validation contract as `summary/2`.
  """
  @spec links(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def links(conn, %{"qid" => qid}) do
    render_by_qid(conn, qid, &Atlas.list_event_links_geojson/1)
  end

  @doc """
  Renders the timeline density histogram for `from`/`to`/`buckets` (`200`),
  or a structured validation error (`422`, not `index/2`'s `400`: every
  parameter here is required, `AmanogawaWeb.Params.HistogramQuery`) when
  malformed.

  `from`/`to` are rounded outward to the nearest point of a fixed
  reference grid (`@cache_grid_edges`) before querying, so nearby requests
  converge on the same cacheable window; the response's own `"from"`/
  `"to"` reflect the rounded (served) window, not the raw request, and
  `cache-control` advertises `#{@histogram_cache_max_age_seconds}s` of
  freshness on top of that.
  """
  @spec histogram(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def histogram(conn, params) do
    case HistogramQuery.parse(params) do
      {:ok, %{from: from, to: to, buckets: buckets}} ->
        {rounded_from, rounded_to} = round_to_cache_grid(from, to)

        conn
        |> put_resp_header(
          "cache-control",
          "public, max-age=#{@histogram_cache_max_age_seconds}"
        )
        |> json(Atlas.event_histogram(%{from: rounded_from, to: rounded_to, buckets: buckets}))

      {:error, errors} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end

  # Snaps `from` down and `to` up to the nearest `@cache_grid_edges` point:
  # the served window is always at least as wide as the one requested,
  # never narrower (a caller's events are never silently dropped by the
  # rounding), and at most one grid step wider on each side.
  defp round_to_cache_grid(from, to) do
    rounded_from =
      @cache_grid_edges
      |> Enum.filter(&(&1 <= from))
      |> List.last() || List.first(@cache_grid_edges)

    rounded_to =
      @cache_grid_edges
      |> Enum.filter(&(&1 >= to))
      |> List.first() || List.last(@cache_grid_edges)

    {rounded_from, rounded_to}
  end

  defp render_by_qid(conn, qid, fetch) do
    if EventId.valid?(qid) do
      case fetch.(qid) do
        {:ok, payload} -> json(conn, payload)
        {:error, :not_found} -> not_found(conn)
      end
    else
      bad_request(conn)
    end
  end

  defp bad_request(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{qid: ["must be a Wikidata QID, e.g. Q12345"]}})
  end

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{qid: ["not found"]}})
  end
end
