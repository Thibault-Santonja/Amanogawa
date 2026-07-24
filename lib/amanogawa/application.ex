defmodule Amanogawa.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        AmanogawaWeb.Telemetry,
        Amanogawa.Repo,
        {DNSCluster, query: Application.get_env(:amanogawa, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Amanogawa.PubSub},
        {Oban, Application.fetch_env!(:amanogawa, Oban)},
        AmanogawaWeb.RateLimit
      ] ++
        error_reporter_child() ++
        [
          # Start to serve requests, typically the last entry
          AmanogawaWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Amanogawa.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AmanogawaWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Alerting (issue #028): disabled in test (`config/test.exs` sets
  # `:start_error_reporter` to `false`) so the many deliberate `:error`
  # logs throughout the test suite (ingestion's hostile-fixture tests
  # among others) never attach a global `:logger` handler that drives a
  # real alert or an unexpected call to a Mox notifier no test in
  # question set up. Tests of `Amanogawa.Alerting.ErrorReporter` itself
  # start and attach their own instance with `start_supervised!/2`.
  defp error_reporter_child do
    if Application.get_env(:amanogawa, :start_error_reporter, true) do
      [Amanogawa.Alerting.ErrorReporter]
    else
      []
    end
  end
end
