defmodule AmanogawaWeb.UserAuthTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.Scope
  alias Amanogawa.Accounts.SessionToken
  alias AmanogawaWeb.Endpoint
  alias AmanogawaWeb.UserAuth

  describe "log_in_user/2" do
    test "creates a session token, stores it in the session, and redirects to /", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == ~p"/"
      assert clear_token = get_session(conn, "user_session_token")
      assert Accounts.get_user_by_session_token(clear_token).id == user.id
      assert get_session(conn, "live_socket_id") =~ "users_sessions:"
    end

    test "redirects to the stashed return path when present", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_return_to", "/compte")
        |> UserAuth.log_in_user(user)

      assert redirected_to(conn) == "/compte"
    end

    test "anti-fixation: an arbitrary pre-login session key does not survive login", %{
      conn: conn
    } do
      user = user_fixture()

      conn =
        conn
        |> init_test_session(%{})
        |> put_session(:some, "thing")
        |> UserAuth.log_in_user(user)

      refute get_session(conn, :some)
    end
  end

  describe "log_out_user/1" do
    test "deletes the session token server-side, disconnects the live socket, and redirects", %{
      conn: conn
    } do
      user = user_fixture()
      {:ok, {clear_token, session_token}} = Accounts.create_session_token(user)
      live_socket_id = UserAuth.live_socket_id(session_token.id)

      Endpoint.subscribe(live_socket_id)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> put_session("live_socket_id", live_socket_id)
        |> UserAuth.log_out_user()

      assert redirected_to(conn) == ~p"/"
      assert Accounts.get_user_by_session_token(clear_token) == nil
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "logging out with no session present does not raise", %{conn: conn} do
      conn = conn |> init_test_session(%{}) |> UserAuth.log_out_user()
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "fetch_current_scope_for_user/2" do
    test "assigns a Scope with the user when the session token is valid", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: %{id: id}} = conn.assigns.current_scope
      assert id == user.id
    end

    test "assigns a Scope with a nil user, never a bare nil, when there is no session", %{
      conn: conn
    } do
      conn =
        conn
        |> init_test_session(%{})
        |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: nil} = conn.assigns.current_scope
    end

    test "renews a session older than 7 days and updates the cookie in place", %{conn: conn} do
      old_inserted_at = DateTime.add(DateTime.utc_now(), -8, :day)
      {clear_token, session_token} = session_token_fixture(inserted_at: old_inserted_at)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: %{id: user_id}} = conn.assigns.current_scope
      assert user_id == session_token.user_id

      new_token = get_session(conn, "user_session_token")
      refute new_token == clear_token
      assert Amanogawa.Repo.aggregate(SessionToken, :count) == 1
    end

    test "does not renew a recent session", %{conn: conn} do
      user = user_fixture()
      {:ok, {clear_token, _session_token}} = Accounts.create_session_token(user)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert get_session(conn, "user_session_token") == clear_token
    end
  end

  describe "require_authenticated_user/2" do
    test "passes through an authenticated conn unchanged", %{conn: conn} do
      user = user_fixture()

      conn =
        conn
        |> log_in_user(user)
        |> UserAuth.fetch_current_scope_for_user([])
        |> UserAuth.require_authenticated_user([])

      refute conn.halted
    end

    test "halts and redirects to /connexion for an anonymous conn, stashing the return path", %{
      conn: conn
    } do
      conn =
        conn
        |> init_test_session(%{})
        |> Map.put(:path_info, ["compte", "export"])
        |> Map.put(:request_path, "/compte/export")
        |> Map.put(:method, "GET")
        |> UserAuth.fetch_current_scope_for_user([])
        |> Phoenix.Controller.fetch_flash([])
        |> UserAuth.require_authenticated_user([])

      assert conn.halted
      assert redirected_to(conn) == ~p"/connexion"
      assert get_session(conn, "user_return_to") == "/compte/export"
    end
  end
end
