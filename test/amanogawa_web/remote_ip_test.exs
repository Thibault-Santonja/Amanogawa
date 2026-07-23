defmodule AmanogawaWeb.RemoteIpTest do
  @moduledoc """
  Integration test for the `RemoteIp` plug wired into
  `AmanogawaWeb.Endpoint` (security review #4): a forwarding header is
  only trusted to correct `conn.remote_ip` when it is unwound down to a
  hop that is itself a configured trusted proxy, so
  `AmanogawaWeb.Plugs.RateLimit`'s per-IP quota key cannot be spoofed by a
  client sending its own `X-Forwarded-For`.
  """
  use AmanogawaWeb.ConnCase, async: false

  # async: false: every test here mutates the shared `:amanogawa,
  # :trusted_proxies` Application env, which `AmanogawaWeb.Endpoint.
  # trusted_proxies/0` (the RemoteIp plug's MFA option) reads fresh on
  # every request.
  setup do
    on_exit(fn -> Application.delete_env(:amanogawa, :trusted_proxies) end)
  end

  test "unwinds X-Forwarded-For when the last hop is a configured trusted proxy", %{conn: conn} do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5"])

    conn =
      conn
      |> put_req_header("x-forwarded-for", "9.9.9.9, 203.0.113.5")
      |> get(~p"/")

    assert conn.remote_ip == {9, 9, 9, 9}
  end

  test "an untrusted last hop is kept as-is: the deeper claimed client IP is ignored (spoof ignored)",
       %{conn: conn} do
    Application.put_env(:amanogawa, :trusted_proxies, ["203.0.113.5"])

    conn =
      conn
      |> put_req_header("x-forwarded-for", "9.9.9.9, 198.51.100.1")
      |> get(~p"/")

    refute conn.remote_ip == {9, 9, 9, 9}
    assert conn.remote_ip == {198, 51, 100, 1}
  end

  test "with no trusted proxies configured (the default), the real connecting peer is untouched",
       %{conn: conn} do
    conn = get(conn, ~p"/")

    assert conn.remote_ip == {127, 0, 0, 1}
  end
end
