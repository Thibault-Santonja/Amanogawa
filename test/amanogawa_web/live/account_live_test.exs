defmodule AmanogawaWeb.AccountLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.DecisionNotifierMock
  alias Amanogawa.Repo

  setup :verify_on_exit!

  setup do
    stub(DecisionNotifierMock, :deliver, fn _email, _outcome, _message, _path, _locale -> :ok end)
    :ok
  end

  describe "mount + handle_params" do
    test "connected, /compte shows the email, creation date, and the current session", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/compte")

      assert html =~ user.email
      assert has_element?(lv, "#sessions")
      assert has_element?(lv, "li", "Session courante")
    end

    test "issue #036: setting a display name persists it, editable at any time", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")

      lv
      |> form("#display-name-form", %{"display_name" => %{"display_name" => "Contributeur"}})
      |> render_submit()

      assert Accounts.get_user!(user.id).display_name == "Contributeur"
      assert render(lv) =~ "Pseudonyme enregistré"
    end

    test "issue #036: a display name already taken by another account is rejected", %{conn: conn} do
      user_fixture(display_name: nil)
      taken = unique_display_name()
      _other = user_fixture() |> Accounts.set_display_name(taken) |> then(fn {:ok, u} -> u end)

      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")

      html =
        lv
        |> form("#display-name-form", %{"display_name" => %{"display_name" => taken}})
        |> render_submit()

      # The changeset message is served TRANSLATED (i18n review finding):
      # the default locale is fr.
      assert html =~ "est déjà utilisé"
      assert Accounts.get_user!(user.id).display_name == nil
    end

    test "anonymous, /compte redirects to /connexion", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/connexion"}}} = live(conn, ~p"/compte")
    end

    test "anonymous, /compte stashes the return path: logging in comes back to /compte", %{
      conn: conn
    } do
      # The initial GET goes through the :authenticated pipeline's
      # require_authenticated_user plug, which stores "user_return_to"
      # before redirecting (the on_mount hook alone never could: it runs
      # on the websocket join, after the HTTP response is long gone).
      conn = get(conn, ~p"/compte")
      assert redirected_to(conn) == ~p"/connexion"
      assert get_session(conn, "user_return_to") == "/compte"

      {:ok, {clear_token, _magic_link}} =
        Amanogawa.Accounts.generate_magic_link_token(unique_email())

      conn = post(conn, ~p"/connexion/#{clear_token}")
      assert redirected_to(conn) == "/compte"
    end
  end

  describe "revocation" do
    test "revoking another session removes it from the list and its token stops resolving", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {other_clear_token, other_session} = session_token_fixture(user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/compte")
      assert has_element?(lv, "#sessions-#{other_session.id}")

      lv
      |> element("#sessions-#{other_session.id} button", "Révoquer")
      |> render_click()

      refute has_element?(lv, "#sessions-#{other_session.id}")
      assert Accounts.get_user_by_session_token(other_clear_token) == nil
    end

    test "revoking the current session disconnects and redirects to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")

      current_session_id =
        Accounts.list_session_tokens(user) |> List.first() |> Map.fetch!(:id)

      lv
      |> element("#sessions-#{current_session_id} button", "Révoquer")
      |> render_click()

      assert_redirect(lv, "/")
    end

    test "revoke_other_sessions revokes every session except the current one", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      {other_clear_token, _other_session} = session_token_fixture(user_id: user.id)

      {:ok, lv, _html} = live(conn, ~p"/compte")

      lv |> element("button", "Révoquer toutes les autres sessions") |> render_click()

      assert Accounts.get_user_by_session_token(other_clear_token) == nil
      assert Repo.aggregate(SessionToken, :count) == 1
    end
  end

  describe "account deletion" do
    test "the two-step flow deletes the account, disconnects, and redirects to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")

      lv |> element("button", "Supprimer mon compte") |> render_click()
      assert has_element?(lv, "#delete-account-form")

      lv
      |> form("#delete-account-form", %{"confirmation" => user.email})
      |> render_submit()

      assert_redirect(lv, "/")
      assert Repo.aggregate(Amanogawa.Accounts.User, :count) == 0
    end

    test "the confirmation input is labelled and associated (for/id)", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")
      lv |> element("button", "Supprimer mon compte") |> render_click()

      assert has_element?(lv, ~s(label[for="delete-confirmation"]))
      assert has_element?(lv, ~s(input#delete-confirmation[name="confirmation"]))
    end

    test "edge case: the confirmation is case- and whitespace-insensitive, like every other email entry point",
         %{conn: conn} do
      user = user_fixture(email: "person@example.com")
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")
      lv |> element("button", "Supprimer mon compte") |> render_click()

      lv
      |> form("#delete-account-form", %{"confirmation" => "  Person@Example.COM  "})
      |> render_submit()

      assert_redirect(lv, "/")
      assert Repo.aggregate(Amanogawa.Accounts.User, :count) == 0
    end

    test "a wrong confirmation deletes nothing and shows an error", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, lv, _html} = live(conn, ~p"/compte")
      lv |> element("button", "Supprimer mon compte") |> render_click()

      html =
        lv
        |> form("#delete-account-form", %{"confirmation" => "wrong@example.com"})
        |> render_submit()

      assert html =~ "ne correspond pas"
      assert Repo.aggregate(Amanogawa.Accounts.User, :count) == 1
    end

    test "M4, RGPD chain end to end: deleting a contributor anonymizes every trace, the public history stays coherent and the corrected value stays served",
         %{conn: conn} do
      author = user_fixture()
      {:ok, author} = Accounts.set_display_name(author, unique_display_name())
      reviewer = reviewer_fixture()
      event = event_fixture(label_fr: "Ancien nom")

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => "Nom corrigé"},
            source: "https://example.org/source"
          },
          author.id
        )

      {:ok, _accepted} = Contributions.accept_override(override.id, reviewer, "Source vérifiée")

      # Deletion goes through the REAL account form, not the domain
      # function directly: the whole chain (AccountLive ->
      # Contributions.anonymize_user/1 -> Accounts.delete_user/1) is what
      # this test covers.
      conn = log_in_user(conn, author)
      {:ok, lv, _html} = live(conn, ~p"/compte")

      lv |> element("button", "Supprimer mon compte") |> render_click()

      lv
      |> form("#delete-account-form", %{"confirmation" => author.email})
      |> render_submit()

      assert_redirect(lv, "/")

      # The account is gone; the contribution's factual content survives,
      # attribution does not.
      assert Accounts.get_user_by_email(author.email) == nil

      reloaded = Contributions.get_override(override.id)
      assert reloaded.author_id == nil
      assert reloaded.status == :accepted

      revisions = Contributions.list_revisions(override.id)
      assert Enum.any?(revisions, &(&1.action == :anonymized))
      assert Enum.find(revisions, &(&1.action == :proposed)).actor_id == nil
      # The reviewer's own attribution is untouched.
      assert Enum.find(revisions, &(&1.action == :accepted)).actor_id == reviewer.id

      # Public feed and detail page both render "compte supprimé", never
      # the deleted account's pseudonym or email.
      anon_conn = build_conn()
      {:ok, _feed_lv, feed_html} = live(anon_conn, ~p"/contributions")
      assert feed_html =~ "compte supprimé"
      refute feed_html =~ author.email

      {:ok, _detail_lv, detail_html} = live(anon_conn, ~p"/contributions/#{override.id}")
      assert detail_html =~ "compte supprimé"
      refute detail_html =~ author.display_name
      refute detail_html =~ author.email

      # The corrected value is still what the map serves.
      assert Atlas.get_event_by_qid(event.qid).label_fr == "Nom corrigé"
      {:ok, _explore_lv, explore_html} = live(anon_conn, ~p"/?sel=#{event.qid}")
      assert explore_html =~ "Nom corrigé"
    end
  end
end
