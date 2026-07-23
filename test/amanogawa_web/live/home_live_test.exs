defmodule AmanogawaWeb.HomeLiveTest do
  use AmanogawaWeb.ConnCase, async: true

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
    test "renders the topbar, the map container, and the timeline strip", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/")

      assert html =~ "Amanogawa"
      assert has_element?(lv, "header#topbar", "Amanogawa")
      assert has_element?(lv, "main#map-zone")
      assert has_element?(lv, "#map")
      assert has_element?(lv, "footer#timeline")
    end

    test "exposes the map hook DOM contract on the map container", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, ~s(#map[phx-hook="MapHook"][phx-update="ignore"]))
    end
  end
end
