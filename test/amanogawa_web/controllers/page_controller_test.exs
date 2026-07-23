defmodule AmanogawaWeb.PageControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  describe "GET /sources" do
    test "200 with the five source sections and their exact license names", %{conn: conn} do
      html = conn |> get(~p"/sources") |> html_response(200)

      assert html =~ "Wikidata"
      assert html =~ "CC0 1.0"
      assert html =~ "Wikipedia"
      assert html =~ "CC BY-SA 4.0"
      assert html =~ "Cliopatria"
      assert html =~ "CC BY 4.0"
      assert html =~ "historical-basemaps"
      assert html =~ "GPL-3.0"
      assert html =~ "OpenFreeMap"
      assert html =~ "ODbL"
    end

    test "edge case: the imprecision disclaimer and every expected href are present", %{
      conn: conn
    } do
      html = conn |> get(~p"/sources") |> html_response(200)

      assert html =~ "zones d&#39;influence approximatives par nature"
      assert html =~ "https://www.wikidata.org"
      assert html =~ "https://zenodo.org/records/14714684"
      assert html =~ "https://github.com/aourednik/historical-basemaps"
      assert html =~ "https://creativecommons.org/publicdomain/zero/1.0/"
      assert html =~ "https://creativecommons.org/licenses/by-sa/4.0/"
      assert html =~ "https://creativecommons.org/licenses/by/4.0/"
      assert html =~ "https://www.gnu.org/licenses/gpl-3.0.html"
      assert html =~ "https://www.openstreetmap.org"
      assert html =~ "https://opendatacommons.org/licenses/odbl/"
    end

    test "limit case: locale=en returns 200 with the translated content", %{conn: conn} do
      html = conn |> get(~p"/sources?locale=en") |> html_response(200)

      assert html =~ "Sources and about"
      assert html =~ "zones of influence"
    end
  end

  describe "GET /mentions-legales" do
    test "200 with the host (Hetzner) and the AGPL license", %{conn: conn} do
      html = conn |> get(~p"/mentions-legales") |> html_response(200)

      assert html =~ "Hetzner"
      assert html =~ "AGPL-3.0"
      assert html =~ "https://github.com/Thibault-Santonja/Amanogawa"
    end

    test "limit case: locale=en returns 200 with the translated content", %{conn: conn} do
      html = conn |> get(~p"/mentions-legales?locale=en") |> html_response(200)

      assert html =~ "Legal notice"
      assert html =~ "Hetzner"
    end
  end

  describe "GET /confidentialite" do
    test "200 with the no-cookie and no-personal-data claims", %{conn: conn} do
      html = conn |> get(~p"/confidentialite") |> html_response(200)

      assert html =~ "aucun cookie"
      assert html =~ "aucune donnée personnelle"
    end

    test "limit case: locale=en returns 200 with the translated content", %{conn: conn} do
      html = conn |> get(~p"/confidentialite?locale=en") |> html_response(200)

      assert html =~ "No personal data collected"
      assert html =~ "No cookies, no trackers"
    end
  end

  describe "locale fallback" do
    test "an unknown locale falls back to French without a 500", %{conn: conn} do
      html = conn |> get(~p"/sources?locale=xx") |> html_response(200)

      assert html =~ "Sources et à propos"
    end
  end

  describe "footer, links and external link hygiene" do
    test "the home page footer links to the three pages and the AGPL repository", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ ~s(href="/sources")
      assert html =~ ~s(href="/mentions-legales")
      assert html =~ ~s(href="/confidentialite")
      assert html =~ "https://github.com/Thibault-Santonja/Amanogawa"
    end

    test "every external link on /sources carries rel=noopener noreferrer", %{conn: conn} do
      html = conn |> get(~p"/sources") |> html_response(200)

      external_links = Regex.scan(~r/<a href="https?:\/\/[^"]+"[^>]*>/, html)
      assert external_links != []

      Enum.each(external_links, fn [tag] ->
        assert tag =~ ~s(rel="noopener noreferrer")
      end)
    end
  end

  describe "no session, no cookie for an anonymous visitor" do
    test "GET /sources sets no set-cookie header", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "GET /mentions-legales sets no set-cookie header", %{conn: conn} do
      conn = get(conn, ~p"/mentions-legales")
      assert get_resp_header(conn, "set-cookie") == []
    end

    test "GET /confidentialite sets no set-cookie header", %{conn: conn} do
      conn = get(conn, ~p"/confidentialite")
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  describe "CSP stays strict on the static pages" do
    test "the CSP header on /sources is unchanged from the rest of the app", %{conn: conn} do
      conn = get(conn, ~p"/sources")
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "object-src 'none'"
    end
  end
end
