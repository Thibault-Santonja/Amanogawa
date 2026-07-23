defmodule Amanogawa.HealthCheck.Repo do
  @moduledoc """
  Default `Amanogawa.HealthCheck` implementation: a trivial `SELECT 1`
  against `Amanogawa.Repo` (issue #026).

  Deliberately the simplest possible query, no PostGIS/schema-specific
  logic: `/health` proves the application can reach and query the
  database, not that any particular table or extension is healthy.
  """

  @behaviour Amanogawa.HealthCheck

  alias Amanogawa.Repo

  @impl true
  def check do
    case Repo.query("SELECT 1", []) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
