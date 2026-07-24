defmodule AmanogawaWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use AmanogawaWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint AmanogawaWeb.Endpoint

      use AmanogawaWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import AmanogawaWeb.ConnCase
    end
  end

  setup tags do
    Amanogawa.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Puts a valid, freshly created session token for `user` into `conn`'s
  session (issue #032, on the model of `phx.gen.auth`'s own `ConnCase`
  helper): the exact mechanism `AmanogawaWeb.UserAuth.log_in_user/2`
  itself uses, without going through an HTTP request. Every subsequent
  request or `live/2` call made with the returned conn resolves
  `@current_scope.user` to `user`.
  """
  @spec log_in_user(Plug.Conn.t(), Amanogawa.Accounts.User.t()) :: Plug.Conn.t()
  def log_in_user(conn, user) do
    {:ok, {clear_token, _session_token}} = Amanogawa.Accounts.create_session_token(user)

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("user_session_token", clear_token)
  end

  @doc """
  Inserts a fresh user (`Amanogawa.AccountsFixtures.user_fixture/1`) and
  logs it into `conn` (`log_in_user/2`): returns `%{conn:, user:}` merged
  into the test context, the shape `setup :register_and_log_in_user`
  expects.
  """
  @spec register_and_log_in_user(%{conn: Plug.Conn.t()}) :: %{conn: Plug.Conn.t(), user: term()}
  def register_and_log_in_user(%{conn: conn}) do
    user = Amanogawa.AccountsFixtures.user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
