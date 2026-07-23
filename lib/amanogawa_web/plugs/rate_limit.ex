defmodule AmanogawaWeb.Plugs.RateLimit do
  @moduledoc """
  Rate limits requests per client IP, applied to the `:api` pipeline
  (`.claude/rules/security.md`: "public JSON endpoints rate limited per
  IP").

  Backed by `AmanogawaWeb.RateLimit` (Hammer, ETS, fixed window). The quota
  (`:limit` requests per `:scale_ms` window) is read from
  `config :amanogawa, AmanogawaWeb.RateLimit` on every request, not baked
  into the router at compile time: this is what lets
  `config/runtime.exs` change the quota per environment without a rebuild,
  and lets tests exercise the 429 path with a small configured quota.

  A denied request halts the pipeline with `429 Too Many Requests`, a JSON
  body `%{"errors" => %{"rate_limit" => [message]}}`, and a `retry-after`
  header (seconds until the window resets).
  """

  @behaviour Plug

  import Plug.Conn

  alias AmanogawaWeb.RateLimit

  @default_limit 120
  @default_scale_ms :timer.minutes(1)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    {limit, scale_ms} = quota(opts)

    case RateLimit.hit(client_key(conn), scale_ms, limit) do
      {:allow, _count} -> conn
      {:deny, retry_after_ms} -> deny(conn, retry_after_ms)
    end
  end

  defp quota(opts) do
    config = Application.get_env(:amanogawa, RateLimit, [])

    limit = Keyword.get(opts, :limit) || Keyword.get(config, :limit, @default_limit)
    scale_ms = Keyword.get(opts, :scale_ms) || Keyword.get(config, :scale_ms, @default_scale_ms)

    {limit, scale_ms}
  end

  # The rate-limit key is scoped to the client IP alone: every public JSON
  # endpoint sharing this plug is meant to share one per-IP quota rather
  # than getting an independent budget per route.
  defp client_key(conn), do: conn.remote_ip |> :inet.ntoa() |> to_string()

  defp deny(conn, retry_after_ms) do
    retry_after_seconds = div(retry_after_ms + 999, 1000)

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> put_status(:too_many_requests)
    |> Phoenix.Controller.json(%{
      errors: %{rate_limit: ["too many requests, retry after #{retry_after_seconds}s"]}
    })
    |> halt()
  end
end
