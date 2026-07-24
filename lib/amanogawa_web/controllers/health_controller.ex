defmodule AmanogawaWeb.HealthController do
  @moduledoc """
  Liveness endpoint (`GET /health`, issue #026): the contract kamal-proxy
  uses to decide whether a container may receive traffic, and the first
  thing an operator checks after a deploy (`docs/ops/deploy.md`).

  Kept on its own `:health` router pipeline (`AmanogawaWeb.Router`),
  outside `:browser` (no session, no CSRF, no cookie) and outside `:api`
  (no rate limiting: kamal-proxy polls this frequently by design).

  The response never leaks internal detail (no hostname, no database URL,
  no stacktrace): only a status and the running application version.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.HealthCheck

  @doc """
  `200` with `{"status": "ok", "version": ...}` when the database check
  succeeds, `503` with `{"status": "unavailable"}` otherwise.
  """
  @spec check(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def check(conn, _params) do
    case HealthCheck.check() do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{status: "ok", version: version()})

      :error ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "unavailable"})
    end
  end

  defp version, do: Application.spec(:amanogawa, :vsn) |> to_string()
end
