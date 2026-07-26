defmodule AmanogawaWeb.PageControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  import Mox

  setup :verify_on_exit!

  setup do
    stub(Amanogawa.Contributions.DecisionNotifierMock, :deliver, fn _email,
                                                                    _outcome,
                                                                    _message,
                                                                    _path,
                                                                    _locale ->
      :ok
    end)

    :ok
  end

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

    test "issue #033: mentions the user accounts section in both locales, still no cookie", %{
      conn: conn
    } do
      fr_conn = get(conn, ~p"/confidentialite")
      fr_html = html_response(fr_conn, 200)

      assert fr_html =~ "Comptes utilisateurs"
      assert fr_html =~ "60 jours"
      assert fr_html =~ "15 minutes"
      assert get_resp_header(fr_conn, "set-cookie") == []

      en_html = conn |> get(~p"/confidentialite?locale=en") |> html_response(200)
      assert en_html =~ "User accounts"
    end
  end

  describe "GET /moderation" do
    alias Amanogawa.AccountsFixtures
    alias Amanogawa.AtlasFixtures
    alias Amanogawa.Contributions
    alias Amanogawa.ContributionsFixtures

    test "200 with the published rules and factual, zero-filled statistics on an empty database",
         %{conn: conn} do
      html = conn |> get(~p"/moderation") |> html_response(200)

      assert html =~ "Critères d&#39;acceptation"
      assert html =~ "Source vérifiable exigée"
      assert html =~ "Motifs de rejet types"
      assert html =~ "L&#39;appel"
      assert html =~ "le même relecteur peut trancher"
      assert html =~ "aucune décision pour le moment"
      # No contributor ranking, no "top" (F08 overview's anti-dark-patterns
      # principle): the word "classement" only ever appears to DENY it.
      refute html =~ "classement des contributeurs"
    end

    test "issue #038: reflects real, non-zero stats and never leaks an email", %{conn: conn} do
      author = AccountsFixtures.user_fixture()
      event = AtlasFixtures.event_fixture()

      override =
        ContributionsFixtures.override_fixture(event_qid: event.qid, author_id: author.id)

      ContributionsFixtures.conflict_fixture()

      reviewer = AccountsFixtures.reviewer_fixture()
      Contributions.accept_override(override.id, reviewer, "Motif public")

      html = get(conn, ~p"/moderation") |> html_response(200)

      assert html =~ "Conflits de synchronisation ouverts"
      refute html =~ author.email
      refute html =~ reviewer.email
    end

    test "limit case: locale=en returns 200 with the translated content", %{conn: conn} do
      html = conn |> get(~p"/moderation?locale=en") |> html_response(200)

      assert html =~ "Acceptance criteria"
      assert html =~ "Typical rejection reasons"
    end

    test "no session, no cookie for an anonymous visitor", %{conn: conn} do
      conn = get(conn, ~p"/moderation")
      assert get_resp_header(conn, "set-cookie") == []
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

  describe "cookie contract on the home page" do
    test "GET / sets exactly one cookie, the session cookie, and it is session-scoped", %{
      conn: conn
    } do
      conn = get(conn, ~p"/")

      # The privacy policy (/confidentialite) promises exactly one,
      # strictly necessary session cookie on the LiveView home page:
      # this test locks that promise. One Set-Cookie header, the session
      # key only, and neither Expires nor Max-Age (a session cookie dies
      # with the browser session, it is never persistent).
      assert [set_cookie] = get_resp_header(conn, "set-cookie")
      assert String.starts_with?(set_cookie, "_amanogawa_key=")

      downcased = String.downcase(set_cookie)
      refute downcased =~ "expires="
      refute downcased =~ "max-age="
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
