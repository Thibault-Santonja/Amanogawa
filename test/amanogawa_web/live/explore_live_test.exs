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

    test "renders the hover card's translated labels as data-i18n-* attributes on #map", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#map[data-i18n-text-label="Texte"]))
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

    test "select_event does not repush an unchanged time window or camera view", %{conn: conn} do
      event = event_fixture(label_fr: "Chute de Constantinople")
      {:ok, lv, _html} = live(conn, ~p"/")

      # Drains the connected mount's own pushes (there is no previous view
      # to compare against yet, so mount always pushes both) before
      # exercising `select_event`, which changes only the selection.
      assert_push_event(lv, "set_time_window", %{})
      assert_push_event(lv, "set_view", %{})
      assert_push_event(lv, "event_deselected", %{qid: nil})

      lv |> element("#map") |> render_hook("select_event", %{"qid" => event.qid})

      assert_push_event(lv, "event_selected", %{qid: qid})
      assert qid == event.qid

      # The window/camera did not change: no redundant `/api/events`
      # refetch or camera re-animation should be triggered in the hook.
      refute_push_event(lv, "set_time_window", %{})
      refute_push_event(lv, "set_view", %{})
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

  describe "handle_event: select_event rate limiting" do
    test "requests beyond the dedicated selection quota are ignored, without a crash and without a patch",
         %{conn: conn} do
      event = event_fixture()
      conn = put_peer_ip(conn, unique_ip())
      {:ok, lv, _html} = live(conn, ~p"/")

      # config/test.exs caps AmanogawaWeb.ExploreLive's selection quota at
      # 3/minute: three full select/deselect round trips exhaust it.
      for _ <- 1..3 do
        lv |> element("#map") |> render_hook("select_event", %{"qid" => event.qid})
        assert has_element?(lv, "#event-panel")

        lv |> element("#map") |> render_hook("deselect_event", %{})
        refute has_element?(lv, "#event-panel")
      end

      lv |> element("#map") |> render_hook("select_event", %{"qid" => event.qid})

      refute has_element?(lv, "#event-panel")
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

  describe "event panel content (issue #016)" do
    test "shows the formatted begin date, extract, attribution and a Wikipedia link", %{
      conn: conn
    } do
      event =
        event_fixture(
          label_fr: "Bataille de Marathon",
          begin_year: -489,
          begin_precision: 9,
          extract_fr: "Resume de la bataille",
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon"
        )

      {:ok, lv, html} = live(conn, ~p"/?sel=#{event.qid}")

      assert html =~ "490 av. J.-C."
      assert html =~ "Resume de la bataille"
      assert html =~ "CC BY-SA 4.0"

      assert has_element?(
               lv,
               ~s(a[href="https://fr.wikipedia.org/wiki/Bataille_de_Marathon"][target="_blank"][rel="noopener noreferrer"])
             )
    end

    test "an extract containing a script tag is rendered escaped, never executed", %{conn: conn} do
      event = event_fixture(extract_fr: "<script>alert(1)</script>")

      {:ok, _lv, html} = live(conn, ~p"/?sel=#{event.qid}")

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
      refute html =~ "<script>alert(1)</script>"
    end

    test "an event without a thumbnail renders no img tag inside the panel", %{conn: conn} do
      event = event_fixture(thumbnail_url: nil)

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}")

      refute has_element?(lv, "#event-panel img")
    end

    test "an event with a thumbnail renders it with the label as alt text", %{conn: conn} do
      event =
        event_fixture(
          label_fr: "Bataille de Marathon",
          thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg"
        )

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}")

      assert has_element?(
               lv,
               ~s(#event-panel img[src="https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg"][alt="Bataille de Marathon"])
             )
    end

    test "an event without an extract shows no attribution or Wikipedia link", %{conn: conn} do
      event = event_fixture(extract_fr: nil, extract_en: nil, wiki_url_fr: nil, wiki_url_en: nil)

      {:ok, lv, html} = live(conn, ~p"/?sel=#{event.qid}")

      refute html =~ "CC BY-SA"
      refute has_element?(lv, "#event-panel a[target=\"_blank\"]")
    end
  end

  describe "event panel accessibility (security review)" do
    test "the panel carries an aria-label and is focusable (tabindex -1, phx-mounted)", %{
      conn: conn
    } do
      event = event_fixture()

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}")

      assert has_element?(lv, "#event-panel[aria-label]")
      assert has_element?(lv, "#event-panel[tabindex='-1']")
      assert has_element?(lv, "#event-panel[phx-mounted]")
    end

    test "Escape closes the panel (phx-window-keydown, bound only while the panel is mounted)",
         %{conn: conn} do
      event = event_fixture(label_fr: "Chute de Constantinople")

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}")
      assert has_element?(lv, "#event-panel")

      lv |> element("#event-panel") |> render_keydown(%{"key" => "Escape"})

      assert_patch(lv, ~p"/")
      refute has_element?(lv, "#event-panel")
    end

    test "no #event-panel element exists to bind Escape to when no event is selected", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/")

      refute has_element?(lv, "#event-panel")
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

  # A unique fake remote IP per call: what gives the rate-limiting test its
  # own isolated Hammer bucket, distinct from every other test's default
  # (127.0.0.1) peer, mirroring
  # AmanogawaWeb.Controllers.Api.EventControllerTest's own `unique_conn/1`.
  #
  # `get_connect_info(socket, :peer_data)` (the LiveView socket, read by
  # `AmanogawaWeb.ExploreLive.peer_ip/1`) resolves through
  # `Plug.Conn.get_peer_data/1`, which reads the test adapter's own
  # `peer_data` payload field, entirely independent of `conn.remote_ip`
  # (unlike `AmanogawaWeb.Plugs.RateLimit`'s `client_key/1`, which reads
  # `conn.remote_ip` directly): `Plug.Test.put_peer_data/2` is the one that
  # actually reaches it.
  defp put_peer_ip(conn, ip),
    do: Plug.Test.put_peer_data(conn, %{address: ip, port: 111_317, ssl_cert: nil})

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
