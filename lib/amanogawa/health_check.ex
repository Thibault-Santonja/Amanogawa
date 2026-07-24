defmodule Amanogawa.HealthCheck do
  @moduledoc """
  Behaviour and dispatch facade for the `/health` liveness check
  (issue #026, `AmanogawaWeb.HealthController`).

  `check/0` is the entry point the controller calls: it dispatches to the
  configured implementation (`config :amanogawa, :health_check`, defaulting
  to `Amanogawa.HealthCheck.Repo`, the same "behaviour + config-selected
  adapter" shape as `Amanogawa.Ingestion.SparqlClient`) bounded by a short
  timeout, so a wedged database connection makes the endpoint answer `503`
  quickly instead of hanging kamal-proxy's health probe indefinitely.

  Tests swap the adapter with `Amanogawa.HealthCheckMock` (Mox); the one
  real-database integration test stubs the mock to delegate to
  `Amanogawa.HealthCheck.Repo.check/0` instead of hardcoding a different
  config value, keeping the single `config :amanogawa, :health_check`
  entry (`config/test.exs`) consistent with every other Mox-backed port in
  this codebase.
  """

  @doc "Checks the dependency this implementation is responsible for."
  @callback check() :: :ok | {:error, term()}

  # Bounded so a hanging DB connection cannot hang the health endpoint:
  # kamal-proxy's own healthcheck has a timeout (`config/deploy.yml`), but
  # this is the last line of defense inside the app itself.
  @default_timeout_ms 2_000

  @doc """
  Runs the configured health check implementation, bounded by a timeout.

  Returns `:ok` when the check completes successfully within the timeout,
  `:error` otherwise (failure, exception, or timeout: the controller never
  needs to distinguish the three, all three mean "unavailable").
  """
  @spec check() :: :ok | :error
  def check do
    task = Task.async(fn -> safe_check(impl()) end)

    case Task.yield(task, timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> :ok
      _timeout_or_error -> :error
    end
  end

  defp safe_check(module) do
    case module.check() do
      :ok -> :ok
      {:error, _reason} -> :error
    end
  rescue
    _exception -> :error
  catch
    # A stopped Repo (or any dependency that exits instead of raising,
    # `DBConnection` does on a missing pool) must degrade to a plain 503,
    # never crash the linked caller into a 500: `Task.async/1` links this
    # process to the endpoint's request process.
    :exit, _reason -> :error
  end

  defp impl, do: Application.get_env(:amanogawa, :health_check, Amanogawa.HealthCheck.Repo)

  defp timeout_ms,
    do: Application.get_env(:amanogawa, __MODULE__, timeout_ms: @default_timeout_ms)[:timeout_ms]
end
