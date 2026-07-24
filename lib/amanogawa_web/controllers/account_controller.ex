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

  @doc """
  Responds with `Amanogawa.Accounts.export_user_data/1`'s map,
  `application/json`, as an attachment (`content-disposition`), never
  cached (`cache-control: no-store`): a personal-data response must
  never linger in an intermediate cache or the browser's own.
  """
  @spec export(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def export(conn, _params) do
    user = conn.assigns.current_scope.user
    filename = "amanogawa-export-#{Date.to_iso8601(Date.utc_today())}.json"

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Jason.encode!(Accounts.export_user_data(user)))
  end
end
