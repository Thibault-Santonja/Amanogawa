defmodule AmanogawaWeb.Controllers.Api.BorderControllerTest do
  # Rate limiting is shared, application-wide state (Hammer/ETS), not reset
  # by the DB sandbox between tests. Every test below uses its own fake
  # remote IP (`unique_conn/1`), so concurrent tests never share a
  # rate-limit bucket and `async: true` stays safe (mirrors
  # `EventControllerTest`'s own rationale).
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas

  describe "GET /api/borders" do
    test "valid year returns 200, JSON content-type and a FeatureCollection", %{conn: conn} do
      polity = polity_fixture(name: "Roman Empire")
      border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      conn = conn |> unique_conn() |> get(~p"/api/borders?year=0")

      assert json_response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)
      assert body["type"] == "FeatureCollection"
      assert [%{"properties" => %{"name" => "Roman Empire"}}] = body["features"]
    end

    test "a year without matching borders returns 200 with an empty FeatureCollection", %{
      conn: conn
    } do
      conn = conn |> unique_conn() |> get(~p"/api/borders?year=50000")

      assert %{"type" => "FeatureCollection", "features" => []} = json_response(conn, 200)
    end

    test "a year outside the data domain is clamped, not rejected", %{conn: conn} do
      polity = polity_fixture(name: "Roman Empire")
      border_fixture(polity_id: polity.id, from_year: -123_000, to_year: -123_000)

      conn = conn |> unique_conn() |> get(~p"/api/borders?year=-999999999")

      assert %{"features" => [%{"properties" => %{"name" => "Roman Empire"}}]} =
               json_response(conn, 200)
    end

    test "a missing year returns 400 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/borders")

      assert %{"errors" => %{"year" => [_message]}} = json_response(conn, 400)
    end

    test "a non-integer year returns 400 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/borders?year=abc")

      assert %{"errors" => %{"year" => [_message]}} = json_response(conn, 400)
    end

    test "carries an ETag and a public Cache-Control header capped at one hour", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/borders?year=0")

      assert [etag] = get_resp_header(conn, "etag")
      assert etag =~ ~r/^"[0-9a-f]+"$/

      assert [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "public"
      # One hour, not longer: within max-age a client never revalidates,
      # so this caps how long a fresh import can stay invisible to an
      # already-primed client (the ETag only matters after expiry).
      assert cache_control =~ "max-age=3600"
    end

    test "a matching If-None-Match returns 304 with no body", %{conn: conn} do
      first = conn |> unique_conn() |> get(~p"/api/borders?year=0")
      assert [etag] = get_resp_header(first, "etag")

      second =
        conn
        |> unique_conn()
        |> put_req_header("if-none-match", etag)
        |> get(~p"/api/borders?year=0")

      assert second.status == 304
      assert second.resp_body == ""
    end

    test "a stale If-None-Match (an older import) returns a fresh 200, not a 304", %{conn: conn} do
      conn = conn |> unique_conn()
      response = get(conn, ~p"/api/borders?year=0")
      assert [stale_etag] = get_resp_header(response, "etag")

      polity = polity_fixture(name: "Roman Empire")
      border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      response =
        conn
        |> put_req_header("if-none-match", stale_etag)
        |> get(~p"/api/borders?year=0")

      assert response.status == 200
      assert [fresh_etag] = get_resp_header(response, "etag")
      assert fresh_etag != stale_etag
    end

    test "the ETag is stable across two requests for the same year with no import in between", %{
      conn: conn
    } do
      first = conn |> unique_conn() |> get(~p"/api/borders?year=0")
      second = conn |> unique_conn() |> get(~p"/api/borders?year=0")

      assert get_resp_header(first, "etag") == get_resp_header(second, "etag")
    end

    test "the ETag differs for two different years", %{conn: conn} do
      first = conn |> unique_conn() |> get(~p"/api/borders?year=0")
      second = conn |> unique_conn() |> get(~p"/api/borders?year=500")

      assert get_resp_header(first, "etag") != get_resp_header(second, "etag")
    end

    test "the ETag changes when the row count changes even if max(updated_at) does not", %{
      conn: conn
    } do
      # Two imports landing within the same second share max(updated_at)
      # (truncated to the second); pinning both rows' updated_at to the
      # same instant reproduces that exactly. The count(*) folded into the
      # hash is what must still invalidate the cache.
      same_instant = ~U[2026-01-01 00:00:00Z]
      polity = polity_fixture(name: "Roman Empire")

      first_border = border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      first_border
      |> Ecto.Changeset.change(updated_at: same_instant)
      |> Amanogawa.Repo.update!()

      first = conn |> unique_conn() |> get(~p"/api/borders?year=0")
      assert [first_etag] = get_resp_header(first, "etag")

      second_border = border_fixture(polity_id: polity.id, from_year: -100, to_year: 100)

      second_border
      |> Ecto.Changeset.change(updated_at: same_instant)
      |> Amanogawa.Repo.update!()

      second = conn |> unique_conn() |> get(~p"/api/borders?year=0")
      assert [second_etag] = get_resp_header(second, "etag")

      assert first_etag != second_etag
    end

    test "exceeding the rate limit quota returns 429 with retry-after", %{conn: conn} do
      ip = unique_ip()

      # config/test.exs caps AmanogawaWeb.RateLimit at 5 requests/minute.
      responses =
        for _ <- 1..6 do
          conn |> put_remote_ip(ip) |> get(~p"/api/borders?year=0")
        end

      assert Enum.count(responses, &(&1.status in [200, 304])) == 5
      assert [denied] = Enum.filter(responses, &(&1.status == 429))

      assert %{"errors" => %{"rate_limit" => [_message]}} = json_response(denied, 429)
      assert [retry_after] = get_resp_header(denied, "retry-after")
      assert {seconds, ""} = Integer.parse(retry_after)
      assert seconds > 0
    end
  end

  test "last_border_import_at/0 sanity: importing advances it, matching the ETag behavior above" do
    assert Atlas.last_border_import_at() == nil

    polity = polity_fixture()
    border_fixture(polity_id: polity.id)

    assert %DateTime{} = Atlas.last_border_import_at()
  end

  defp unique_conn(conn), do: put_remote_ip(conn, unique_ip())

  defp put_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
