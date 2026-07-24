defmodule AmanogawaWeb.ClientIpTest do
  @moduledoc """
  Unit tests for `AmanogawaWeb.ClientIp` (security review F07): the
  LiveView-socket counterpart of `AmanogawaWeb.RemoteIpTest`, exercising
  the exact `connect_info` shape the endpoint exposes (`:peer_data` and
  `:x_headers`) as a plain map, the way `Phoenix.LiveView.
  get_connect_info/2` reads it on a real socket.
  """

  # async: false: every test here mutates the shared `:amanogawa,
  # :trusted_proxies` Application env, which `AmanogawaWeb.Endpoint.
  # trusted_proxies/0` reads fresh on every resolution (exactly like
  # AmanogawaWeb.RemoteIpTest).
  use ExUnit.Case, async: false

  alias AmanogawaWeb.ClientIp

  setup do
    on_exit(fn -> Application.delete_env(:amanogawa, :trusted_proxies) end)
  end

  defp socket(connect_info) do
    %Phoenix.LiveView.Socket{private: %{connect_info: connect_info}}
  end

  defp socket_with(peer, x_headers) do
    socket(%{peer_data: %{address: peer}, x_headers: x_headers})
  end

  test "happy path: X-Forwarded-For through a configured trusted proxy resolves the real client" do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5"])

    socket = socket_with({203, 0, 113, 5}, [{"x-forwarded-for", "9.9.9.9"}])

    assert ClientIp.peer_ip(socket) == {9, 9, 9, 9}
  end

  test "happy path: a multi-hop chain is unwound down to the deepest non-proxy hop" do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5", "203.0.113.6"])

    socket = socket_with({203, 0, 113, 5}, [{"x-forwarded-for", "9.9.9.9, 203.0.113.6"}])

    assert ClientIp.peer_ip(socket) == {9, 9, 9, 9}
  end

  test "error case: a spoofed X-Forwarded-For from an untrusted public peer is ignored" do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5"])

    socket = socket_with({198, 51, 100, 7}, [{"x-forwarded-for", "9.9.9.9"}])

    assert ClientIp.peer_ip(socket) == {198, 51, 100, 7}
  end

  test "edge case: no forwarding headers at all (dev/test) falls back to peer_data unchanged" do
    assert ClientIp.peer_ip(socket_with({127, 0, 0, 1}, [])) == {127, 0, 0, 1}
    assert ClientIp.peer_ip(socket_with({192, 168, 1, 20}, [])) == {192, 168, 1, 20}
  end

  test "edge case: connect_info without peer_data resolves to nil (no client to throttle)" do
    assert ClientIp.peer_ip(socket(%{})) == nil
    assert ClientIp.peer_ip(socket(%{x_headers: [{"x-forwarded-for", "9.9.9.9"}]})) == nil
  end

  test "edge case: a socket with no connect_info at all resolves to nil" do
    assert ClientIp.peer_ip(%Phoenix.LiveView.Socket{}) == nil
  end

  test "limit case: a chain of nothing but proxies falls back to the peer" do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5"])

    socket = socket_with({203, 0, 113, 5}, [{"x-forwarded-for", "203.0.113.5"}])

    assert ClientIp.peer_ip(socket) == {203, 0, 113, 5}
  end
end
