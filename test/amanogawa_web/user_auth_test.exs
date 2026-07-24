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

    test "limit case: a 61-day-old token is never renewed, resolves anonymous now and later", %{
      conn: conn
    } do
      # The resurrection bug this locks out: an expired token used to
      # resolve to no user but still went through renewal, which minted a
      # brand new 60-day session from a dead one.
      inserted_at = DateTime.add(DateTime.utc_now(), -61, :day)
      {clear_token, _session_token} = session_token_fixture(inserted_at: inserted_at)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: nil} = conn.assigns.current_scope
      # No replacement row was minted: the expired row is the only one.
      assert Amanogawa.Repo.aggregate(SessionToken, :count) == 1
      assert get_session(conn, "user_session_token") == clear_token

      # The next request presenting the same cookie is anonymous too.
      next_conn =
        Phoenix.ConnTest.build_conn()
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> UserAuth.fetch_current_scope_for_user([])

      assert %Scope{user: nil} = next_conn.assigns.current_scope
      assert Amanogawa.Repo.aggregate(SessionToken, :count) == 1
    end

    test "limit case: two concurrent requests renewing the same old session never crash", %{
      conn: conn
    } do
      inserted_at = DateTime.add(DateTime.utc_now(), -8, :day)
      {clear_token, session_token} = session_token_fixture(inserted_at: inserted_at)

      # The double-request scenario a real browser produces (two parallel
      # navigations carrying the same old cookie): with the non-atomic
      # replacement this raised Ecto.StaleEntryError (a 500) on the loser.
      [conn_a, conn_b] =
        [conn, Phoenix.ConnTest.build_conn()]
        |> Enum.map(fn c ->
          Task.async(fn ->
            c
            |> init_test_session(%{})
            |> put_session("user_session_token", clear_token)
            |> UserAuth.fetch_current_scope_for_user([])
          end)
        end)
        |> Task.await_many()

      assert %Scope{user: %{id: user_id}} = conn_a.assigns.current_scope
      assert %Scope{user: %{id: ^user_id}} = conn_b.assigns.current_scope
      assert user_id == session_token.user_id

      # Exactly one winner minted a replacement; the loser kept serving
      # the old token for this response.
      assert Amanogawa.Repo.aggregate(SessionToken, :count) == 1

      renewed_tokens =
        [conn_a, conn_b]
        |> Enum.map(&get_session(&1, "user_session_token"))
        |> Enum.reject(&(&1 == clear_token))

      assert [new_clear_token] = renewed_tokens
      assert Accounts.get_user_by_session_token(new_clear_token).id == user_id
    end

    test "renewal broadcasts disconnect on the OLD live_socket_id once the response is sent", %{
      conn: conn
    } do
      # LiveView sockets mounted under the old token would otherwise
      # outlive it unrevocably (their session row no longer exists, so
      # #033's account page cannot list or revoke them). Asserted at the
      # PubSub level rather than through LiveViewTest: the disconnect is
      # broadcast from a plug's `register_before_send` on a LATER request
      # than the one that mounted the LiveView, and LiveViewTest's mocked
      # transport has no cookie jar to carry the renewed session between
      # those two requests the way a real browser does.
      inserted_at = DateTime.add(DateTime.utc_now(), -8, :day)
      {clear_token, session_token} = session_token_fixture(inserted_at: inserted_at)
      old_live_socket_id = UserAuth.live_socket_id(session_token.id)

      Endpoint.subscribe(old_live_socket_id)

      conn =
        conn
        |> init_test_session(%{})
        |> put_session("user_session_token", clear_token)
        |> put_session("live_socket_id", old_live_socket_id)
        |> get(~p"/")

      new_token = get_session(conn, "user_session_token")
      refute new_token == clear_token

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^old_live_socket_id,
        event: "disconnect"
      }
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
