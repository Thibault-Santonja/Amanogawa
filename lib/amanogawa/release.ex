defmodule Amanogawa.Release do
  @moduledoc """
  Release tasks executed from the compiled release, without Mix (issue
  #026, standard Phoenix "Deploying with releases" pattern: `mix` is a
  build-time tool, never shipped in the runtime image).

  Invoked from `rel/overlays/bin/docker-entrypoint` on every container
  start, before `bin/amanogawa start`:

      bin/amanogawa eval "Amanogawa.Release.migrate()"

  `Ecto.Migrator`'s own advisory lock protects a rolling deploy where two
  containers briefly overlap: the second container's `migrate/0` blocks on
  the lock until the first one releases it, rather than racing it.

  Every migration shipped after this issue must stay compatible with the
  previous release (`docs/ops/deploy.md`, "Zero downtime"): additive
  changes, expand/contract for anything destructive, never drop a column
  or table still read by the version about to be replaced.
  """

  @app :amanogawa

  @doc """
  Runs every pending migration for every configured repo (`atlas` and
  `ingestion` schemas both live in `Amanogawa.Repo`, see
  `config :amanogawa, ecto_repos`).
  """
  @spec migrate() :: :ok
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _fun_return, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end

  @doc """
  Rolls a single repo back to `version` (an operator-invoked escape hatch,
  never run automatically at deploy time).
  """
  @spec rollback(Ecto.Repo.t(), non_neg_integer()) :: :ok
  def rollback(repo, version) do
    load_app()

    {:ok, _fun_return, _apps} =
      Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))

    :ok
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp load_app do
    # Many platforms (and Postgrex's own `ssl: true` option, commented out
    # in `config/runtime.exs` pending a target host that requires it)
    # require the :ssl application to be started before connecting to the
    # database; harmless to start unconditionally.
    Application.ensure_all_started(:ssl)
    Application.load(@app)
  end
end
