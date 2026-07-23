defmodule Amanogawa.Repo.Migrations.CreateIngestionSyncRuns do
  use Ecto.Migration

  @moduledoc """
  Creates `ingestion.sync_runs`, the trace of every ingestion pipeline
  execution (events, links, summaries): status, timestamps, counters and the
  resume cursor. This is what makes a worker run observable, idempotent
  (rerunning is a no-op once `completed`) and resumable after failure (the
  `cursor` column is the source of truth for where a `failed` run left off).
  """

  def change do
    create table(:sync_runs, primary_key: false, prefix: "ingestion") do
      add :id, :binary_id, primary_key: true

      add :kind, :string, null: false
      add :status, :string, null: false

      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime

      add :counts, :map, null: false, default: %{}
      add :cursor, :map
      add :last_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:sync_runs, [:kind, :started_at], prefix: "ingestion")
  end
end
