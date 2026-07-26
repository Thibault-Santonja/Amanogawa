defmodule AmanogawaWeb.AccountController do
  @moduledoc """
  `GET /compte/export` (issue #033, RGPD article 20 portability): the one
  controller-only route under the authenticated scope, since a plain
  `Plug.Conn` response (a downloadable JSON attachment) has no reason to
  be a LiveView. Gated by `AmanogawaWeb.UserAuth.require_authenticated_user/2`
  on the router's `:authenticated` pipeline.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Accounts
  alias Amanogawa.Contributions

  @doc """
  Responds with the user's full data export, `application/json`, as an
  attachment (`content-disposition`), never cached (`cache-control:
  no-store`): a personal-data response must never linger in an
  intermediate cache or the browser's own.

  Composes `Amanogawa.Accounts.export_user_data/1` (`format_version: 1`)
  with `Amanogawa.Contributions.export_user_contributions/1` HERE, in the
  web layer (issue #038, F08 overview: "la composition se fait dans la
  couche web, Accounts n'apprend jamais l'existence de Contributions"),
  overriding `format_version` to `2` and adding the `:contributions` key:
  a pre-F08 account with no contribution still exports cleanly, with an
  empty list.
  """
  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    user = conn.assigns.current_scope.user
    filename = "amanogawa-export-#{Date.to_iso8601(Date.utc_today())}.json"

    export_data =
      user
      |> Accounts.export_user_data()
      |> Map.put(:format_version, 2)
      |> Map.put(:contributions, Contributions.export_user_contributions(user))

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Jason.encode!(export_data))
  end
end
