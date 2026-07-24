defmodule AmanogawaWeb.LoggingIntegrationTest do
  @moduledoc """
  Integration test for `Amanogawa.Logging.JSONFormatter` (issue #028):
  proves the formatter renders a real request's own `request_id`
  (`Plug.RequestId`, `AmanogawaWeb.Endpoint`) as valid JSON, the same
  wiring production uses (`config/runtime.exs`'s `:default_formatter`
  override), without mutating global test configuration:
  `ExUnit.CaptureLog.capture_log/2`'s `:format` option overrides the
  formatter only for the duration of the capture.

  `ExUnit.CaptureLog`'s own moduledoc is explicit that, under `async:
  true`, "messages from other tests might be captured" (it mutes the
  single global handler for the duration of the call, not a
  per-process one): with the JSON formatter emitting one object per
  line, an unrelated concurrent `:error` log from another async test
  (for example `Amanogawa.Accounts.deliver_magic_link/3`'s own
  logged notifier failure) can legitimately land in the same captured
  string. This test isolates its own line by `request_id` before
  decoding, rather than assuming the whole capture is exactly one JSON
  document.
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

    own_line =
      log
      |> String.split("\n", trim: true)
      |> Enum.find(&(&1 =~ request_id))

    assert %{"level" => "error", "message" => "integration check", "request_id" => ^request_id} =
             Jason.decode!(own_line)
  end
end
