defmodule AmanogawaWeb.Controllers.Api.EventControllerTest do
  # Rate limiting is shared, application-wide state (Hammer/ETS), not reset
  # by the DB sandbox between tests. Every test below uses its own fake
  # remote IP (`unique_conn/1`), so concurrent tests never share a
  # rate-limit bucket and `async: true` stays safe.
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AtlasFixtures

  describe "GET /api/events" do
    test "valid params return 200, JSON content-type and a FeatureCollection", %{conn: conn} do
      event_fixture(qid: "Q1")

      conn =
        conn
        |> unique_conn()
        |> get(~p"/api/events?bbox=-180,-90,180,90&from=-13800000000&to=2026&limit=10")

      assert json_response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)
      assert body["type"] == "FeatureCollection"
      assert [%{"properties" => %{"qid" => "Q1"}}] = body["features"]
    end

    test "no params defaults to the whole world and full time range", %{conn: conn} do
      event_fixture(qid: "Q1")

      conn = conn |> unique_conn() |> get(~p"/api/events")

      assert %{"features" => [%{"properties" => %{"qid" => "Q1"}}]} = json_response(conn, 200)
    end

    test "invalid bbox returns 400 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events?bbox=invalid")

      assert %{"errors" => %{"bbox" => [_message]}} = json_response(conn, 400)
    end

    test "from greater than to returns 400 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events?from=500&to=-500")

      assert %{"errors" => %{"from" => [_message]}} = json_response(conn, 400)
    end

    test "exceeding the rate limit quota returns 429 with retry-after", %{conn: conn} do
      ip = unique_ip()

      # config/test.exs caps AmanogawaWeb.RateLimit at 5 requests/minute.
      responses =
        for _ <- 1..6 do
          conn |> put_remote_ip(ip) |> get(~p"/api/events")
        end

      assert Enum.count(responses, &(&1.status == 200)) == 5
      assert [denied] = Enum.filter(responses, &(&1.status == 429))

      assert %{"errors" => %{"rate_limit" => [_message]}} = json_response(denied, 429)
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
    end
  end

  defp unique_conn(conn), do: put_remote_ip(conn, unique_ip())

  defp put_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
