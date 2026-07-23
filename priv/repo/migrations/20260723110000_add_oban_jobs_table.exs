defmodule Amanogawa.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  @moduledoc """
  Creates Oban's job table (default `public` schema, per Oban's own
  convention): background work for the ingestion pipelines (`.claude/rules/
  architecture.md`, "Oban for background jobs, not GenServer") runs through
  it.
  """

  def up do
    Oban.Migration.up(version: 14)
  end

  def down do
    Oban.Migration.down(version: 1)
  end
end
