defmodule AmanogawaWeb.ExploreLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AtlasFixtures
  import Phoenix.LiveViewTest

  describe "GET /" do
    test "responds 200 with the French root layout and the CSP header", %{conn: conn} do
      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~ ~r/<html[^>]*lang="fr"/
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
    end
  end

  describe "mount" do
    test "renders the topbar, the map container, and the timeline strip with defaults, no panel open",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Amanogawa"
      assert has_element?(lv, "header#topbar", "Amanogawa")
      assert has_element?(lv, "main#map-zone")
      assert has_element?(lv, "#map")
      assert has_element?(lv, "footer#timeline")
      refute has_element?(lv, "#event-panel")
    end

    test "exposes the map hook DOM contract on the map container", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#map[phx-hook="MapHook"][phx-update="ignore"]))
    end

    test "mount/3 issues no database query (LiveView iron law: no DB in mount)" do
      # Calls `mount/3` directly, as a plain function, rather than through
      # `live/2`: Ecto's query telemetry fires in the process that issued
      # the query, so filtering on `self() == test_pid` here isolates this
      # assertion from unrelated queries other, concurrently running async
      # tests emit under their own LiveView processes.
      test_pid = self()
      handler_id = {:explore_live_mount_query_check, make_ref()}

      :telemetry.attach(
        handler_id,
        [:amanogawa, :repo, :query],
        fn _event, _measurements, _metadata, _config ->
          if self() == test_pid, do: send(test_pid, :query_executed)
        end,
        nil
      )

      assert {:ok, _socket} = AmanogawaWeb.ExploreLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

      refute_receive :query_executed, 100

      :telemetry.detach(handler_id)
    end
  end

  describe "handle_params: from/to" do
    test "a URL with from/to pushes set_time_window with the parsed bounds", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/?from=-500&to=500")

      assert_push_event(lv, "set_time_window", %{from: -500, to: 500})
    end
  end

  describe "handle_params: selection" do
    test "a URL with a valid sel renders the panel and pushes event_selected", %{conn: conn} do
      event = event_fixture(label_fr: "Bataille de Marathon")
      qid = event.qid

      {:ok, lv, html} = live(conn, ~p"/?sel=#{event.qid}")

      assert html =~ "Bataille de Marathon"
      assert has_element?(lv, "#event-panel", "Bataille de Marathon")
      assert_push_event(lv, "event_selected", %{qid: ^qid})
    end

    test "a URL with an unknown sel renders no panel", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/?sel=Q999999999")

      refute has_element?(lv, "#event-panel")
    end

    test "a URL without sel pushes event_deselected", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert_push_event(lv, "event_deselected", %{qid: nil})
    end
  end

  describe "handle_event: select_event / deselect_event" do
    test "select_event patches the URL with sel and opens the panel", %{conn: conn} do
      event = event_fixture(label_fr: "Chute de Constantinople")
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("select_event", %{"qid" => event.qid})

      assert_patch(lv, ~p"/?sel=#{event.qid}")
      assert has_element?(lv, "#event-panel", "Chute de Constantinople")
    end

    test "deselect_event removes sel from the URL and closes the panel", %{conn: conn} do
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}")

      assert has_element?(lv, "#event-panel")

      lv |> element("#map") |> render_hook("deselect_event", %{})

      assert_patch(lv, ~p"/")
      refute has_element?(lv, "#event-panel")
    end

    test "select_event with a malformed qid is ignored", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("select_event", %{"qid" => "not-a-qid"})

      refute has_element?(lv, "#event-panel")
    end

    test "select_event without a qid key at all is ignored, not a crash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("select_event", %{})

      refute_patched(lv)
      assert Process.alive?(lv.pid)
    end
  end

  describe "handle_event: map_moved" do
    test "a valid payload patches the URL with z/lat/lng", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv
      |> element("#map")
      |> render_hook("map_moved", %{"z" => 4.5, "lat" => 10.0, "lng" => -20.0})

      # `URI.encode_query/1` enumerates map keys in sorted order.
      assert_patch(lv, ~p"/?lat=10.0&lng=-20.0&z=4.5")
    end

    test "a hostile payload leaves the current view unchanged and does not crash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/?lat=10.0&lng=-20.0&z=4.5")

      lv
      |> element("#map")
      |> render_hook("map_moved", %{"z" => 999, "lat" => "abc", "lng" => -20.0})

      # No push_patch was issued at all for the rejected payload.
      refute_patched(lv)
      assert Process.alive?(lv.pid)
    end

    test "a payload missing z/lat/lng entirely is ignored, not a crash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("map_moved", %{})

      refute_patched(lv)
      assert Process.alive?(lv.pid)
    end
  end

  describe "handle_event: set_time_window" do
    test "a valid payload patches the URL with from/to", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("set_time_window", %{"from" => -200, "to" => 200})

      assert_patch(lv, ~p"/?from=-200&to=200")
    end

    test "a payload missing from/to entirely is ignored, not a crash", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("set_time_window", %{})

      refute_patched(lv)
      assert Process.alive?(lv.pid)
    end

    test "from > to is rejected without crashing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      lv |> element("#map") |> render_hook("set_time_window", %{"from" => 200, "to" => -200})

      refute_patched(lv)
      assert Process.alive?(lv.pid)
    end
  end

  describe "browser navigation" do
    test "re-applying a previous URL through handle_params restores its state", %{conn: conn} do
      event = event_fixture(label_fr: "Prise de la Bastille")

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&from=-100&to=100")
      assert has_element?(lv, "#event-panel", "Prise de la Bastille")

      # Simulates the browser back button: the client replays a previous
      # URL through the same `live_patch`/`handle_params` path.
      lv |> element("#map") |> render_hook("deselect_event", %{})
      refute has_element?(lv, "#event-panel")

      {:ok, _lv2, html} = live(conn, ~p"/?sel=#{event.qid}&from=-100&to=100")
      assert html =~ "Prise de la Bastille"
    end
  end
end
