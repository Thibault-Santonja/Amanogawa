defmodule AmanogawaWeb.AccountLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Repo

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
      assert has_element?(lv, "form")

      lv
      |> form("form", %{"confirmation" => user.email})
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
      |> form("form", %{"confirmation" => "  Person@Example.COM  "})
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
        |> form("form", %{"confirmation" => "wrong@example.com"})
        |> render_submit()

      assert html =~ "ne correspond pas"
      assert Repo.aggregate(Amanogawa.Accounts.User, :count) == 1
    end
  end
end
