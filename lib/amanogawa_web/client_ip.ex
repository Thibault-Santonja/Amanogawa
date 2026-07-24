defmodule AmanogawaWeb.ClientIp do
  @moduledoc """
  Resolves the real client IP of a LiveView socket (issue security-review
  F07: per-client rate limiting behind a reverse proxy).

  LiveView sockets never go through the endpoint's HTTP plug pipeline, so
  the `RemoteIp` plug never corrects their address: behind kamal-proxy,
  `:peer_data` is always the proxy's own address, which would collapse
  every real client into one shared rate-limit bucket
  (`AmanogawaWeb.LoginLive`'s magic link throttle,
  `AmanogawaWeb.ExploreLive`'s selection throttle). This helper applies
  the same resolution the HTTP pipeline gets from the `RemoteIp` plug:
  the socket's `:x_headers` (exposed in the endpoint's `connect_info`)
  are unwound with `RemoteIp.from/2` against the exact same trusted
  proxy list (`AmanogawaWeb.Endpoint.trusted_proxies/0`, sourced from
  `TRUSTED_PROXIES`).

  The connecting peer is appended to the forwarded chain as its last
  hop, which is precisely how the `RemoteIp` plug itself treats
  `conn.remote_ip`: a forwarding header is only unwound past the peer
  when the peer is a known proxy (configured, loopback, or private
  range), so a direct client spoofing `X-Forwarded-For` resolves to its
  own peer address, never to the forged one. With no forwarding headers
  at all (dev/test, or any deployment without a proxy), resolution
  falls back to `:peer_data` unchanged.
  """

  alias AmanogawaWeb.Endpoint

  @doc """
  The resolved client IP for `socket`, or `nil` when the socket carries
  no connect info at all (a disconnected render, or `mount/3` called
  directly as a plain function in tests): a `nil` here means "no real
  client to throttle", and callers skip rate limiting entirely.

  Only callable where `Phoenix.LiveView.get_connect_info/2` is: during
  mount. Callers capture the result in an assign.
  """
  @spec peer_ip(Phoenix.LiveView.Socket.t()) :: :inet.ip_address() | nil
  def peer_ip(%{private: private} = socket) do
    if Map.has_key?(private, :connect_info) do
      resolve(
        Phoenix.LiveView.get_connect_info(socket, :x_headers) || [],
        peer_address(socket)
      )
    else
      nil
    end
  end

  defp peer_address(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address
      _other -> nil
    end
  end

  defp resolve([], peer), do: peer
  defp resolve(_x_headers, nil), do: nil

  defp resolve(x_headers, peer) do
    chain = x_headers ++ [{"x-forwarded-for", peer |> :inet.ntoa() |> to_string()}]

    RemoteIp.from(chain, proxies: Endpoint.trusted_proxies()) || peer
  end
end
