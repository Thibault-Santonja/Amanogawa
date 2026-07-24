defmodule AmanogawaWeb.E2E.AuthJourneyTest do
  @moduledoc """
  The complete passwordless authentication journey (issue #032) and its
  RGPD extension (issue #033), in a real browser: request a magic link
  from `/connexion`, read it back from the test mailbox
  (`AmanogawaWeb.FeatureCase.share_swoosh_mailbox/0`, `Amanogawa.Mailer`'s
  `Swoosh.Adapters.Test` shared mode), visit the link (confirmation page,
  GET, no side effect), confirm (POST, real submit), land back on `/`
  connected, then either sign out or delete the account from `/compte`.

  Locks the two structural defenses the rest of the suite cannot see
  from a `Phoenix.LiveViewTest`/`ConnTest` process: the GET/POST split
  around the magic link token (a plain HTML form submit, exercised here
  through an actual browser click, not `Phoenix.ConnTest.post/2`), and
  the `phoenix_html`-driven `DELETE /deconnexion` link (`data-method`,
  intercepted client-side, unreachable from a conn test).
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Swoosh.TestAssertions
  import Wallaby.Browser

  alias Amanogawa.AccountsFixtures
  alias Wallaby.Query

  setup do
    # Per-test, not `setup_all` (see the function's own moduledoc):
    # `self()` must be this exact `feature/3` process, the one that later
    # calls `assert_email_sent/1` below.
    AmanogawaWeb.FeatureCase.share_swoosh_mailbox()
    :ok
  end

  feature "request a link, confirm it, land connected, then sign out to anonymous again", %{
    session: session
  } do
    email = AccountsFixtures.unique_email()

    session
    |> visit("/")
    |> assert_has(Query.css("a[href='/connexion']", text: "Connexion"))
    |> click(Query.css("a[href='/connexion']"))

    magic_link_url = request_magic_link(session, email)

    # GET: the confirmation page only, no side effect (anti-prefetch,
    # issue #032's own point d'attention). Visiting it twice must still
    # leave the token redeemable, which the POST just below proves by
    # succeeding.
    session
    |> visit(magic_link_url)
    |> assert_has(Query.css("h1", text: "Confirmer la connexion"))
    |> visit(magic_link_url)
    |> assert_has(Query.css("h1", text: "Confirmer la connexion"))

    # POST: a real form submit click, the only thing that consumes the
    # token and creates the session.
    session
    |> click(Query.css("button", text: "Confirmer la connexion"))
    |> assert_has(Query.css("#topbar", text: email))
    |> wait_for_map_ready()

    session
    |> visit("/compte")
    |> assert_has(Query.css("p", text: email))
    |> assert_has(Query.css("li", text: "Session courante"))
    |> assert_has(Query.css("a[href='/compte/export']"))

    # A second visit to the (now stale) magic link URL: the token no
    # longer redeems (usage-once), so the confirm POST redirects to
    # /connexion with the neutral flash; since THIS browser is still
    # signed in from the successful confirm above, LoginLive's own
    # already-authenticated guard immediately bounces it straight back
    # to /, still connected as the same visitor, rather than dropping
    # back to the login form (which only an anonymous visitor would see,
    # covered separately by `SessionControllerTest`'s own conn test).
    session
    |> visit(magic_link_url)
    |> click(Query.css("button", text: "Confirmer la connexion"))
    |> assert_has(Query.css("#topbar", text: email))

    session
    |> visit("/")
    |> assert_has(Query.css("#topbar", text: email))
    |> click(Query.css("a[href='/deconnexion']", text: "Déconnexion"))
    |> assert_has(Query.css("a[href='/connexion']", text: "Connexion"))
    |> wait_for_map_ready()

    refute has?(session, Query.css("#topbar", text: email))
  end

  feature "deleting the account from /compte returns to anonymous and the old session is dead",
          %{session: session} do
    email = AccountsFixtures.unique_email()

    session |> visit("/") |> click(Query.css("a[href='/connexion']"))
    magic_link_url = request_magic_link(session, email)

    session
    |> visit(magic_link_url)
    |> click(Query.css("button", text: "Confirmer la connexion"))
    |> assert_has(Query.css("#topbar", text: email))

    session
    |> visit("/compte")
    |> assert_has(Query.css("p", text: email))
    |> click(Query.css("button", text: "Supprimer mon compte"))
    |> assert_has(Query.css("form input[name='confirmation']"))
    |> fill_in(Query.css("input[name='confirmation']"), with: email)
    |> click(Query.css("button", text: "Confirmer la suppression"))
    |> assert_has(Query.css("a[href='/connexion']", text: "Connexion"))
    |> wait_for_map_ready()

    refute has?(session, Query.css("#topbar", text: email))

    # The old session's own credential is gone server-side (hard delete,
    # cascaded session tokens): revisiting an authenticated-only page
    # with whatever the browser still holds must resolve anonymous, not
    # reconnect to the deleted account.
    session
    |> visit("/compte")
    |> assert_has(Query.css("#login-form"))
  end

  defp request_magic_link(session, email) do
    session
    |> assert_has(Query.css("#login-form"))
    |> fill_in(Query.css("input[name='login[email]']"), with: email)
    |> click(Query.css("#login-form button", text: "Recevoir un lien de connexion"))
    |> assert_has(Query.css("#magic-link-sent"))

    assert_email_sent(fn sent_email ->
      assert sent_email.to == [{"", email}]

      [url] = Regex.run(~r{https?://\S+/connexion/\S+}, sent_email.text_body)
      send(self(), {:captured_magic_link_url, String.trim(url)})
      true
    end)

    assert_receive {:captured_magic_link_url, magic_link_url}
    magic_link_url
  end
end
