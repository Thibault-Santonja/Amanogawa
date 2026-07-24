defmodule AmanogawaWeb.SessionController do
  @moduledoc """
  Exchanges a magic link for a session (issue #032): the GET/POST split
  around `:token` is the anti-prefetch defense the F07 overview and this
  issue's own context require (`confirm/2` touches nothing, `create/2`
  alone consumes the token), plus plain logout.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Accounts
  alias AmanogawaWeb.UserAuth

  @doc """
  `GET /connexion/:token`: renders a confirmation page whose form POSTs
  the same token. Never touches the database, and in particular never
  calls `redeem_magic_link_token/1`: this is the whole point (a mail
  client or antivirus prefetching this GET must not burn the token before
  the visitor ever clicks).
  """
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    render(conn, :confirm, page_title: gettext("Confirmer la connexion"), token: token)
  end

  @doc """
  `POST /connexion/:token`: the only action that consumes the token.
  Success logs the visitor in with a welcome flash; every failure
  (unknown, expired, already-used, or malformed token) redirects to
  `/connexion` with the exact same neutral flash, never distinguishing
  which (anti-oracle, `Amanogawa.Accounts.redeem_magic_link_token/1`'s
  own invariant).
  """
  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, %{"token" => token}) do
    case Accounts.redeem_magic_link_token(token) do
      {:ok, user} ->
        conn
        |> put_flash(:info, gettext("Connexion réussie, bienvenue !"))
        |> UserAuth.log_in_user(user)

      :error ->
        conn
        |> put_flash(
          :error,
          gettext("Ce lien de connexion est invalide ou a expiré, demandez-en un nouveau.")
        )
        |> redirect(to: ~p"/connexion")
    end
  end

  @doc "`DELETE /deconnexion`: logs the current session out."
  @spec delete(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Vous êtes déconnecté."))
    |> UserAuth.log_out_user()
  end
end
