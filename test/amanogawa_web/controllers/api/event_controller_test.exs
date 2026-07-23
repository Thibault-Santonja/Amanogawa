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
        |> get(
          ~p"/api/events?bbox=-180,-90,180,90&from=-13800000000&to=#{Date.utc_today().year}&limit=10"
        )

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

  describe "GET /api/events/:qid/summary" do
    test "a known QID returns 200 with the expected fields", %{conn: conn} do
      event_fixture(
        qid: "Q31900",
        label_fr: "Bataille de Marathon",
        extract_fr: "Resume francais",
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
        thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg"
      )

      conn = conn |> unique_conn() |> get(~p"/api/events/Q31900/summary")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)

      assert body == %{
               "qid" => "Q31900",
               "label" => "Bataille de Marathon",
               "extract" => "Resume francais",
               "thumbnail_url" =>
                 "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg",
               "wiki_url" => "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
               "extract_language" => "fr",
               "fetched_at" => nil
             }
    end

    test "an unknown but well-formed QID returns 404", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/Q999999999/summary")

      assert %{"errors" => %{"qid" => [_message]}} = json_response(conn, 404)
    end

    test "a malformed QID returns 400 without touching the database", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/not-a-qid/summary")

      assert %{"errors" => %{"qid" => [_message]}} = json_response(conn, 400)
    end

    test "a hostile QID is rejected with 400", %{conn: conn} do
      conn = conn |> unique_conn() |> get("/api/events/#{URI.encode("Q1' OR 1=1")}/summary")

      assert json_response(conn, 400)
    end
  end

  describe "GET /api/events/:qid/links" do
    test "an event with relations returns 200 and the expected FeatureCollection", %{conn: conn} do
      center = event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326})

      target =
        event_fixture(qid: "Q2", geom: %Geo.Point{coordinates: {12.5, 41.9}, srid: 4326})

      event_link_fixture(source_id: center.id, target_id: target.id, type: :cause)

      conn = conn |> unique_conn() |> get(~p"/api/events/Q1/links")

      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      body = json_response(conn, 200)
      assert body["type"] == "FeatureCollection"
      assert [feature] = body["features"]
      assert feature["geometry"]["type"] == "LineString"
      assert feature["properties"]["link_type"] == "cause"
      assert feature["properties"]["target_qid"] == "Q2"
    end

    test "an event without any relation returns 200 with an empty FeatureCollection", %{
      conn: conn
    } do
      event_fixture(qid: "Q1")

      conn = conn |> unique_conn() |> get(~p"/api/events/Q1/links")

      assert %{"type" => "FeatureCollection", "features" => []} = json_response(conn, 200)
    end

    test "an unknown but well-formed QID returns 404", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/Q999999999/links")

      assert %{"errors" => %{"qid" => [_message]}} = json_response(conn, 404)
    end

    test "a malformed QID returns 400 without touching the database", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/not-a-qid/links")

      assert %{"errors" => %{"qid" => [_message]}} = json_response(conn, 400)
    end
  end

  describe "GET /api/events/histogram" do
    test "valid params return 200, JSON content-type, cache headers and a dense bucket list", %{
      conn: conn
    } do
      event_fixture(begin_year: 1789)

      conn = conn |> unique_conn() |> get(~p"/api/events/histogram?from=-1000&to=2000&buckets=5")

      assert json_response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"
      assert [cache_control] = get_resp_header(conn, "cache-control")
      assert cache_control =~ "public"
      assert cache_control =~ "max-age="

      body = json_response(conn, 200)
      assert is_integer(body["from"])
      assert is_integer(body["to"])
      assert length(body["buckets"]) == 5
      assert Enum.sum(Enum.map(body["buckets"], & &1["count"])) == 1
    end

    test "missing from/to returns 422 with structured errors, never a silent default", %{
      conn: conn
    } do
      conn = conn |> unique_conn() |> get(~p"/api/events/histogram")

      assert %{"errors" => %{"from" => [_from_message], "to" => [_to_message]}} =
               json_response(conn, 422)
    end

    test "from >= to returns 422 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/histogram?from=500&to=500")

      assert %{"errors" => %{"from" => [_message]}} = json_response(conn, 422)
    end

    test "buckets out of 1..200 returns 422 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/histogram?from=0&to=100&buckets=201")

      assert %{"errors" => %{"buckets" => [_message]}} = json_response(conn, 422)
    end

    test "a non-integer buckets returns 422 with structured errors", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/histogram?from=0&to=100&buckets=abc")

      assert %{"errors" => %{"buckets" => [_message]}} = json_response(conn, 422)
    end

    test "requested bounds are rounded outward to the cache grid, never narrower", %{conn: conn} do
      conn = conn |> unique_conn() |> get(~p"/api/events/histogram?from=-1&to=1&buckets=2")

      body = json_response(conn, 200)
      assert body["from"] <= -1
      assert body["to"] >= 1
    end

    test "exceeding the rate limit quota returns 429 with retry-after", %{conn: conn} do
      ip = unique_ip()

      responses =
        for _ <- 1..6 do
          conn |> put_remote_ip(ip) |> get(~p"/api/events/histogram?from=0&to=100")
        end

      assert Enum.count(responses, &(&1.status == 200)) == 5
      assert [denied] = Enum.filter(responses, &(&1.status == 429))
      assert %{"errors" => %{"rate_limit" => [_message]}} = json_response(denied, 429)
    end
  end

  defp unique_conn(conn), do: put_remote_ip(conn, unique_ip())

  defp put_remote_ip(conn, ip), do: %{conn | remote_ip: ip}

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
