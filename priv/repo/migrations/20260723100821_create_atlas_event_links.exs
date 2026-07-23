defmodule Amanogawa.Repo.Migrations.CreateAtlasEventLinks do
  use Ecto.Migration

  @moduledoc """
  Creates `atlas.event_links`, typed edges between two `atlas.events` rows
  (`part_of`, `follows`, `cause`, `effect`, `significant`). A given (source,
  target, type) triple is unique, which is what makes ingestion's bulk
  `on_conflict: :nothing` upserts idempotent.
  """

  def change do
    create table(:event_links, primary_key: false, prefix: "atlas") do
      add :id, :binary_id, primary_key: true

      add :source_id,
          references(:events, type: :binary_id, prefix: "atlas", on_delete: :delete_all),
          null: false

      add :target_id,
          references(:events, type: :binary_id, prefix: "atlas", on_delete: :delete_all),
          null: false

      add :type, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:event_links, [:source_id, :target_id, :type], prefix: "atlas")
    create index(:event_links, [:target_id], prefix: "atlas")
  end
end
