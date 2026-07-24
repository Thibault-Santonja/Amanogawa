defmodule AmanogawaWeb.SessionControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Repo

  describe "GET /connexion/:token (confirm/2)" do
    test "renders the confirmation page without consuming the token", %{conn: conn} do
      {:ok, {clear_token, _magic_link}} = Accounts.generate_magic_link_token(unique_email())

      html = conn |> get(~p"/connexion/#{clear_token}") |> html_response(200)

      assert html =~ "Confirmer la connexion"
      assert html =~ ~s(action="/connexion/#{clear_token}")

      # The token is still redeemable: the GET touched nothing.
      assert {:ok, _user} = Accounts.redeem_magic_link_token(clear_token)
    end
  end

  describe "POST /connexion/:token (create/2)" do
    test "a valid token logs the user in, consumes it, and redirects with a welcome flash", %{
      conn: conn
    } do
      {:ok, {clear_token, _magic_link}} = Accounts.generate_magic_link_token(unique_email())

      conn = post(conn, ~p"/connexion/#{clear_token}")

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connexion réussie"
      assert get_session(conn, "user_session_token")
      assert Repo.aggregate(SessionToken, :count) == 1
    end

    test "a second POST of the same token fails with the neutral flash (usage-once)", %{
      conn: conn
    } do
      {:ok, {clear_token, _magic_link}} = Accounts.generate_magic_link_token(unique_email())

      post(conn, ~p"/connexion/#{clear_token}")
      conn = post(conn, ~p"/connexion/#{clear_token}")

      assert redirected_to(conn) == ~p"/connexion"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalide ou a expiré"
    end

    test "an unknown token fails with the exact same neutral flash", %{conn: conn} do
      conn = post(conn, ~p"/connexion/unknown-token")

      assert redirected_to(conn) == ~p"/connexion"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalide ou a expiré"
    end
  end

  describe "DELETE /deconnexion (delete/2)" do
    test "logs the current session out and redirects to /", %{conn: conn} do
      user = user_fixture()
      {:ok, {clear_token, _session_token}} = Accounts.create_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> delete(~p"/deconnexion")

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(clear_token) == nil
    end
  end

  describe "integration: @current_scope through the plug pipeline" do
    test "with a session posed, @current_scope.user is the user", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/")
      assert conn.assigns.current_scope.user.id == user.id
    end

    test "without a session, @current_scope.user is nil", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert conn.assigns.current_scope.user == nil
    end

    test "after DELETE /deconnexion, the session no longer resolves and the token is gone", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)
      clear_token = get_session(conn, "user_session_token")

      conn = delete(conn, ~p"/deconnexion")

      assert Accounts.get_user_by_session_token(clear_token) == nil
      refute get_session(conn, "user_session_token")
    end
  end

  describe "integration: security" do
    test "the session cookie carries no clear-text token beyond Phoenix's own signature", %{
      conn: conn
    } do
      {:ok, {clear_token, _magic_link}} = Accounts.generate_magic_link_token(unique_email())

      conn = post(conn, ~p"/connexion/#{clear_token}")

      assert [set_cookie] = get_resp_header(conn, "set-cookie")
      session_token = get_session(conn, "user_session_token")

      refute set_cookie =~ session_token
    end

    test "configure_session(renew: true) regenerates the session identifier at login", %{
      conn: conn
    } do
      {:ok, {clear_token, _magic_link}} = Accounts.generate_magic_link_token(unique_email())

      anonymous_conn = get(conn, ~p"/")
      assert [before_cookie] = get_resp_header(anonymous_conn, "set-cookie")

      logged_in_conn = anonymous_conn |> recycle() |> post(~p"/connexion/#{clear_token}")
      assert [after_cookie] = get_resp_header(logged_in_conn, "set-cookie")

      refute after_cookie == before_cookie
    end
  end
end
