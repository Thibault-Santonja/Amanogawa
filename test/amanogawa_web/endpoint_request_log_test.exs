defmodule AmanogawaWeb.EndpointRequestLogTest do
  @moduledoc """
  Locks `AmanogawaWeb.Endpoint.telemetry_log_level/1` (security review
  F07): the request log line for `/connexion/<token>` would put the
  clear magic link token, a credential valid for up to 15 minutes, into
  the production logs ("GET /connexion/<token>"), so those requests must
  produce no request log line at all, on GET and POST alike.
  """

  # async: false: the tests temporarily raise the global Logger level to
  # :info (config/test.exs pins it at :warning for quiet output, which
  # would silence the very request lines under test; `capture_log`'s
  # :level option only narrows the capture, it cannot lower the
  # application-wide level), and a globally lowered level must not bleed
  # into concurrent tests.
  use AmanogawaWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  setup do
    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)
  end

  test "GET /connexion/<token> produces no request log line", %{conn: conn} do
    log =
      capture_log([level: :info], fn ->
        conn |> get(~p"/connexion/secret-token-value") |> html_response(200)
      end)

    refute log =~ "secret-token-value"
    refute log =~ "GET /connexion"
  end

  test "POST /connexion/<token> produces no request log line", %{conn: conn} do
    log =
      capture_log([level: :info], fn ->
        conn |> post(~p"/connexion/secret-token-value") |> redirected_to()
      end)

    refute log =~ "secret-token-value"
    refute log =~ "POST /connexion"
  end

  test "positive control: any other request still logs its line", %{conn: conn} do
    # Proves the two negative assertions above test the plug, not a
    # logging setup that never emits request lines in the first place.
    log =
      capture_log([level: :info], fn ->
        conn |> get(~p"/connexion") |> html_response(200)
      end)

    assert log =~ "GET /connexion"
  end
end
