defmodule AmanogawaWeb.Controllers.Api.BorderController do
  @moduledoc """
  Read-only, rate-limited borders endpoint
  (`AmanogawaWeb.Plugs.RateLimit` on the `:api` pipeline), kept
  intentionally thin, mirroring `AmanogawaWeb.Controllers.Api.
  EventController`: parameter parsing and validation live in
  `AmanogawaWeb.Params.BorderQuery`, the query in `Amanogawa.Atlas.
  BorderQueries`, the GeoJSON shaping in `Amanogawa.Atlas`.

    * `GET /api/borders?year=`: the historical borders ("zones of
      influence", ADR 0004: assumed imprecise, never rendered as exact
      lines) active at `year` (`from_year <= year <= to_year`), as a
      GeoJSON `FeatureCollection` at the default simplification level
      (`geom_medium`, issue #023). `year` is required and must be an
      integer (`400` otherwise, `AmanogawaWeb.Params.BorderQuery`); a
      value outside the imported sources' own domain
      (`[-123_000, 2024]`) is clamped, not rejected, since the caller's
      reference year is the timeline window's upper bound
      (`AmanogawaWeb.ExploreLive` moduledoc, F05 design), which ranges
      over the whole event domain and legitimately overshoots the much
      narrower border domain at either edge (issue #025).

  Cacheable by design (ADR 0007): a given year's borders are immutable
  between two imports (`Amanogawa.Atlas.replace_borders/2` is the only
  writer), so every response carries a strong `ETag` derived from
  `(year, Amanogawa.Atlas.last_border_import_at/0)` and a `Cache-Control:
  public, max-age` header; a matching `If-None-Match` short-circuits to
  `304` with no body.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Atlas
  alias AmanogawaWeb.Params.BorderQuery

  # A given (year, import) pair never changes: a full day of client-side
  # freshness is safe on top of the ETag, which already forces a
  # conditional revalidation the moment a new import lands (its own
  # `last_border_import_at/0` timestamp advances, changing the ETag).
  @cache_max_age_seconds 86_400

  # Fallback ETag input when `atlas.borders` is empty (no import has ever
  # run): a fixed epoch rather than `nil`, so `etag_for/1` always has a
  # timestamp to hash, and every "no data yet" response for a given year
  # still shares one stable ETag rather than a fresh one per request.
  @epoch ~U[1970-01-01 00:00:00Z]

  @doc """
  Renders the borders active at `year` (`200`), a structured `400` when
  `year` is missing or not an integer
  (`AmanogawaWeb.Params.BorderQuery.parse/1`), or `304` (no body) when the
  request's `If-None-Match` already names the current ETag.
  """
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    case BorderQuery.parse(params) do
      {:ok, %{year: year}} ->
        render_borders(conn, year)

      {:error, errors} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: errors})
    end
  end

  defp render_borders(conn, year) do
    etag = etag_for(year)

    conn = put_resp_header(conn, "etag", etag)

    if fresh?(conn, etag) do
      send_resp(conn, 304, "")
    else
      conn
      |> put_resp_header("cache-control", "public, max-age=#{@cache_max_age_seconds}")
      |> json(Atlas.list_borders_geojson(year))
    end
  end

  # Matches the caller's `if-none-match` against `etag`, tolerating the
  # header's own comma-separated multi-value grammar (RFC 9110 8.8.3)
  # rather than only ever comparing against a single raw value: a generic
  # HTTP cache in front of this endpoint is free to forward more than one
  # candidate.
  defp fresh?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.member?(etag)
  end

  # Strong ETag (no `W/` prefix: the served bytes for a given `(year,
  # import)` pair are byte-identical, never a semantically-equivalent
  # variant) derived from real data, never hardcoded
  # (`docs/features/005-frontieres-historiques/003-endpoint-rendu-frontieres.md`'s
  # own point d'attention): `Amanogawa.Atlas.last_border_import_at/0` is
  # the single source of truth for "has anything changed since the client
  # cached this", advanced only by a real import
  # (`Amanogawa.Atlas.replace_borders/2`).
  defp etag_for(year) do
    imported_at = Atlas.last_border_import_at() || @epoch

    hash =
      :crypto.hash(:sha256, "#{year}:#{DateTime.to_iso8601(imported_at)}")
      |> Base.encode16(case: :lower)

    ~s("#{hash}")
  end
end
