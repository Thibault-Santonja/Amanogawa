defmodule AmanogawaWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a strict Content-Security-Policy header on browser requests.

  No third-party script, style, or font is ever allowed. Beyond `'self'`,
  the policy only opens what the map requires: MapLibre workers run from
  `blob:` URLs, decoded images use `data:`/`blob:`, vector tiles, glyphs,
  and sprites are fetched from the OpenFreeMap origin, and event
  thumbnails (issue #016) are fetched from the Wikimedia upload origin,
  the only host `Amanogawa.WikimediaUrl.valid_thumbnail?/1` ever accepts
  for a `thumbnail_url` (a strictly narrower check than the general
  `Amanogawa.WikimediaUrl.valid?/1`, which also accepts `*.wikipedia.org`
  article hosts that this CSP does *not* allow as an image source). The
  LiveView websocket origin is derived from the endpoint configuration.
  """
  @behaviour Plug

  import Plug.Conn

  @tiles_origin "https://tiles.openfreemap.org"
  @wikimedia_images_origin "https://upload.wikimedia.org"

  @doc """
  Returns the origin serving map tiles, glyphs, and sprites.

  Exposed so tests can assert that the vendored map styles only reference
  origins allowed by this policy.
  """
  @spec tiles_origin() :: String.t()
  def tiles_origin, do: @tiles_origin

  @doc """
  Returns the origin serving Wikipedia article thumbnails (issue #016).

  Exposed for the same reason as `tiles_origin/0`: tests assert the CSP
  and the actual data source (`Amanogawa.WikimediaUrl.valid_thumbnail?/1`)
  never drift apart.
  """
  @spec wikimedia_images_origin() :: String.t()
  def wikimedia_images_origin, do: @wikimedia_images_origin

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    endpoint = opts[:endpoint] || conn.private.phoenix_endpoint
    put_resp_header(conn, "content-security-policy", policy(endpoint))
  end

  defp policy(endpoint) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self' data: blob: #{@wikimedia_images_origin}",
        "font-src 'self'",
        "connect-src 'self' #{websocket_origin(endpoint)} #{@tiles_origin}",
        "worker-src blob:",
        "child-src blob:",
        "object-src 'none'",
        "manifest-src 'self'",
        "frame-ancestors 'none'",
        "base-uri 'self'",
        "form-action 'self'"
      ],
      "; "
    )
  end

  # The websocket origin is listed explicitly because some browsers do not
  # match ws:/wss: schemes against 'self'.
  defp websocket_origin(endpoint) do
    %URI{scheme: scheme, host: host, port: port} = endpoint.struct_url()
    origin(ws_scheme(scheme), host, port)
  end

  defp ws_scheme("https"), do: "wss"
  defp ws_scheme(_), do: "ws"

  defp origin("ws", host, 80), do: "ws://#{host}"
  defp origin("wss", host, 443), do: "wss://#{host}"
  defp origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"
end
