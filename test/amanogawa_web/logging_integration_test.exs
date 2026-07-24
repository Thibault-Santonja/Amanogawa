defmodule AmanogawaWeb.LoggingIntegrationTest do
  @moduledoc """
  Integration test for `Amanogawa.Logging.JSONFormatter` (issue #028):
  proves the formatter renders a real request's own `request_id`
  (`Plug.RequestId`, `AmanogawaWeb.Endpoint`) as valid JSON, the same
  wiring production uses (`config/runtime.exs`'s `:default_formatter`
  override), without mutating global test configuration:
  `ExUnit.CaptureLog.capture_log/2`'s `:format` option overrides the
  formatter only for the duration of the capture (`ExUnit.CaptureLog`
  moduledoc), leaving every other async test's logging untouched.
  """

  use AmanogawaWeb.ConnCase, async: true

  import ExUnit.CaptureLog

  require Logger

  test "a real request's request_id round-trips through the JSON formatter", %{conn: conn} do
    conn = get(conn, ~p"/sources")
    assert [request_id] = get_resp_header(conn, "x-request-id")

    # config/test.exs sets the global Logger level to :warning (quiet test
    # output): capture_log's own :level option only ever narrows the
    # effective level further, never below the application-wide one, so
    # this logs at :error rather than :info to actually be captured.
    log =
      capture_log([format: {Amanogawa.Logging.JSONFormatter, :format}, level: :error], fn ->
        Logger.error("integration check", request_id: request_id)
      end)

    assert %{"level" => "error", "message" => "integration check", "request_id" => ^request_id} =
             log |> String.trim() |> Jason.decode!()
  end
end
