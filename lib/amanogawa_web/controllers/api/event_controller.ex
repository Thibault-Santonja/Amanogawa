defmodule AmanogawaWeb.Controllers.Api.EventController do
  @moduledoc """
  `GET /api/events?bbox=&from=&to=&limit=`: events for the map viewport
  and time window, ranked by importance, as a bounded GeoJSON
  `FeatureCollection` (issue #014, ADR 0007).

  Read-only, side-effect free, rate limited per IP
  (`AmanogawaWeb.Plugs.RateLimit` on the `:api` pipeline). Kept
  intentionally thin: parameter parsing and validation live in
  `AmanogawaWeb.Params.EventsQuery`, the query itself in
  `Amanogawa.Atlas.EventQueries`, the GeoJSON shaping in
  `Amanogawa.Atlas.list_events_geojson/1`.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Atlas
  alias AmanogawaWeb.Params.EventsQuery

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
end
