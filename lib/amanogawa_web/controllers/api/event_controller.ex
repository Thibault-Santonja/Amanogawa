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
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Atlas
  alias AmanogawaWeb.Params.EventId
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
