defmodule AmanogawaWeb.HealthControllerTest do
  use AmanogawaWeb.ConnCase, async: false

  import Mox

  alias Amanogawa.HealthCheck
  alias Amanogawa.HealthCheck.Repo, as: HealthCheckRepo
  alias Amanogawa.HealthCheckMock

  # Global mode (`async: false` module-wide, see the test case above): the
  # controller runs `Amanogawa.HealthCheck.check/0`, which bounds the
  # configured implementation's call in a `Task.async` process distinct
  # from the test process that sets up the mock's expectations, so private
  # mode's "same process" rule would otherwise reject every call.
  setup :set_mox_global
  setup :verify_on_exit!

  describe "GET /health" do
    test "happy path: 200 with status ok and the running application version", %{conn: conn} do
      expect(HealthCheckMock, :check, fn -> :ok end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 200) == %{
               "status" => "ok",
               "version" => to_string(Application.spec(:amanogawa, :vsn))
             }
    end

    test "edge case: the response body has no key beyond status and version", %{conn: conn} do
      expect(HealthCheckMock, :check, fn -> :ok end)

      conn = get(conn, ~p"/health")

      assert Map.keys(json_response(conn, 200)) |> Enum.sort() == ["status", "version"]
    end

    test "error case: a failed check responds 503 with status unavailable, no leaked detail", %{
      conn: conn
    } do
      expect(HealthCheckMock, :check, fn -> {:error, %DBConnection.ConnectionError{}} end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{"status" => "unavailable"}
    end

    test "error case: an exception during the check also responds 503, never crashes", %{
      conn: conn
    } do
      expect(HealthCheckMock, :check, fn -> raise "boom" end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{"status" => "unavailable"}
    end

    test "error case: a check that exits (stopped Repo) responds 503, never 500", %{conn: conn} do
      # `DBConnection` exits (rather than raises) when its pool is down,
      # exactly what a stopped Repo looks like: the health endpoint must
      # degrade to 503, not crash the request process into a 500.
      expect(HealthCheckMock, :check, fn -> exit(:noproc) end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 503) == %{"status" => "unavailable"}
    end

    test "limit case: a hanging check responds 503 within the configured timeout", %{conn: conn} do
      expect(HealthCheckMock, :check, fn ->
        Process.sleep(:infinity)
      end)

      started_at = System.monotonic_time(:millisecond)
      conn = get(conn, ~p"/health")
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert json_response(conn, 503) == %{"status" => "unavailable"}
      # config/test.exs sets Amanogawa.HealthCheck's timeout to 100ms; a
      # generous ceiling here only guards against the bound being ignored.
      assert elapsed_ms < 2_000
    end

    test "no session, no cookie: the endpoint carries no set-cookie header", %{conn: conn} do
      expect(HealthCheckMock, :check, fn -> :ok end)

      conn = get(conn, ~p"/health")

      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "integration: real database" do
    test "GET /health succeeds against the real test database", %{conn: conn} do
      stub(HealthCheckMock, :check, fn -> HealthCheckRepo.check() end)

      conn = get(conn, ~p"/health")

      assert json_response(conn, 200)["status"] == "ok"
    end
  end

  describe "Amanogawa.HealthCheck.check/0" do
    test "dispatches to the configured implementation" do
      expect(HealthCheckMock, :check, fn -> :ok end)
      assert HealthCheck.check() == :ok
    end
  end
end
