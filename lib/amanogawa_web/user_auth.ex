defmodule AmanogawaWeb.UserAuth do
  @moduledoc """
  The single place session plumbing lives (issue #032, F07 overview): log
  in, log out, resolve `@current_scope` for conns and LiveView sockets,
  and gate the routes that require an authenticated user. On the model of
  `phx.gen.auth`'s Phoenix 1.8 scope-based generator, transposed by hand
  (no generator run, `.claude/rules/architecture.md`).

  ## Session contract

  The Plug session (the signed, HttpOnly `_amanogawa_key` cookie,
  `AmanogawaWeb.Endpoint`) carries exactly two keys once a user is
  signed in, never the user itself:

  * `"user_session_token"`: the opaque clear session token
    (`Amanogawa.Accounts.create_session_token/1`). The row it hashes to
    (`accounts.session_tokens`) is what actually authenticates every
    request; deleting that row (logout, revocation from the account page
    in #033, account deletion) revokes the session immediately,
    server-side, regardless of what the cookie still holds.
  * `"live_socket_id"`: `"users_sessions:<session token id>"`, read
    automatically by `Phoenix.LiveView.Socket.id/1` from
    `connect_info[:session]`. Broadcasting `"disconnect"` on this exact
    topic (`disconnect_session/1`) force-disconnects every LiveView
    socket sharing it, which is how #033's session revocation and
    account deletion take effect immediately instead of waiting for the
    next navigation.

  `configure_session(renew: true)` is called on both login and logout
  (anti-fixation in both directions, F07 overview): the Plug session
  identifier itself is regenerated, on top of the session token
  swap/removal.
  """

  use AmanogawaWeb, :verified_routes
  use Gettext, backend: AmanogawaWeb.Gettext

  import Plug.Conn
  import Phoenix.Controller

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.Scope
  alias AmanogawaWeb.Endpoint

  @user_session_token_key "user_session_token"
  @live_socket_id_prefix "users_sessions:"

  @doc """
  Signs `user` in: creates a session token, regenerates the Plug session
  (anti-fixation), stores the opaque token and the live-socket topic id,
  and redirects to the path stashed by `require_authenticated_user/2`
  (`"user_return_to"`) or `"/"`.
  """
  @spec log_in_user(Plug.Conn.t(), Accounts.User.t()) :: Plug.Conn.t()
  def log_in_user(conn, user) do
    {:ok, {clear_token, session_token}} = Accounts.create_session_token(user)
    user_return_to = get_session(conn, "user_return_to")

    conn
    |> renew_session()
    |> put_session(@user_session_token_key, clear_token)
    |> put_session("live_socket_id", live_socket_id(session_token.id))
    |> redirect(to: user_return_to || ~p"/")
  end

  @doc """
  Signs the current session out: deletes its row server-side (so the
  cookie the browser still holds is immediately worthless), disconnects
  any live socket sharing its `live_socket_id`, regenerates the Plug
  session, and redirects to `/`.
  """
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    conn
    |> get_session(@user_session_token_key)
    |> Accounts.delete_session_token()

    conn
    |> get_session("live_socket_id")
    |> disconnect_session()

    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @doc """
  Broadcasts `"disconnect"` on `live_socket_id` (a
  `"users_sessions:<id>"` topic, see the moduledoc): every LiveView
  socket sharing that id is force-disconnected, so a revoked session
  (logout, #033's per-session revocation, account deletion) stops
  serving that browser tab immediately instead of on its next
  navigation. `nil` is a no-op (no live socket for this conn, or the
  session predates #032).
  """
  @spec disconnect_session(String.t() | nil) :: :ok
  def disconnect_session(nil), do: :ok

  def disconnect_session(live_socket_id) do
    Endpoint.broadcast(live_socket_id, "disconnect", %{})
    :ok
  end

  @doc "The `live_socket_id` topic for the session token row `id`, see the moduledoc."
  @spec live_socket_id(Ecto.UUID.t()) :: String.t()
  def live_socket_id(session_token_id), do: @live_socket_id_prefix <> session_token_id

  @doc """
  Plug: resolves `@current_scope` for every request on the `:browser`
  pipeline (after `:fetch_session`). Always assigns a `Scope`, `user`
  `nil` for an anonymous visitor: never assigns a bare `nil`. Slides the
  session forward when it is old enough (`Amanogawa.Accounts.
  renew_session_token/1`), updating the cookie in the same response. One
  query per navigation: the resolution itself
  (`get_user_by_session_token/1`); renewal is skipped entirely when the
  session was not renewed.
  """
  @spec fetch_current_scope_for_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope_for_user(conn, _opts) do
    case get_session(conn, @user_session_token_key) do
      nil ->
        assign(conn, :current_scope, Scope.for_user(nil))

      clear_token ->
        conn
        |> assign(:current_scope, Scope.for_user(Accounts.get_user_by_session_token(clear_token)))
        |> maybe_renew_session(clear_token)
    end
  end

  @doc """
  Plug: halts and redirects anonymous requests to `/connexion`, stashing
  the current path (`"user_return_to"`) so `log_in_user/2` can send the
  visitor back where they came from. Requires `fetch_current_scope_for_user/2`
  to already have run. Used by controller-only routes under the
  authenticated scope (`/compte/export`, issue #033); the LiveView
  equivalent is `on_mount(:require_authenticated_user, ...)` below.
  """
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(
        :error,
        dgettext("accounts", "Vous devez vous connecter pour accéder à cette page.")
      )
      |> maybe_store_return_to()
      |> redirect(to: ~p"/connexion")
      |> halt()
    end
  end

  @doc """
  `on_mount` hook assigning `@current_scope` from the socket's session
  (`user` possibly `nil`): the sole point resolving it for every
  LiveView under `live_session :current_user` and `:require_authenticated_user`.
  No database query when the session carries no token; exactly one when
  it does. Never runs from `mount/3` bodies (`.claude/rules/liveview.md`):
  this hook IS the sanctioned exception, the same one `phx.gen.auth` uses.
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:mount_current_scope, _params, session, socket) do
    {:cont, mount_current_scope(socket, session)}
  end

  def on_mount(:require_authenticated_user, _params, session, socket) do
    socket = mount_current_scope(socket, session)

    if socket.assigns.current_scope.user do
      {:cont, socket}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(
          :error,
          dgettext("accounts", "Vous devez vous connecter pour accéder à cette page.")
        )
        |> Phoenix.LiveView.redirect(to: ~p"/connexion")

      {:halt, socket}
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      user =
        case session["user_session_token"] do
          nil -> nil
          clear_token -> Accounts.get_user_by_session_token(clear_token)
        end

      Scope.for_user(user)
    end)
  end

  defp maybe_renew_session(conn, clear_token) do
    case Accounts.renew_session_token(clear_token) do
      {:ok, {new_clear_token, new_session_token}} ->
        conn
        |> put_session(@user_session_token_key, new_clear_token)
        |> put_session("live_socket_id", live_socket_id(new_session_token.id))

      :unchanged ->
        conn
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, "user_return_to", current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  # Regenerates the Plug session identifier (anti-fixation, F07 overview:
  # "configure_session(renew: true) au login et au logout") and clears
  # whatever it held before: log_in_user/2 immediately repopulates the two
  # keys the session contract above defines, log_out_user/1 leaves it
  # empty.
  defp renew_session(conn) do
    Plug.CSRFProtection.delete_csrf_token()

    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
