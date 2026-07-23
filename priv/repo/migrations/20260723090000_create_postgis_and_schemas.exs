defmodule Amanogawa.Repo.Migrations.CreatePostgisAndSchemas do
  use Ecto.Migration

  @moduledoc """
  Enables the PostGIS extension and creates the PostgreSQL schemas backing the
  bounded contexts of phase 1: `atlas` (events, polities, borders) and
  `ingestion` (import pipelines). No table is created here: tables arrive with
  their contexts (F02+), each Ecto schema declaring its `@schema_prefix`.
  """

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS postgis"
    execute "CREATE SCHEMA IF NOT EXISTS atlas"
    execute "CREATE SCHEMA IF NOT EXISTS ingestion"
  end

  def down do
    execute "DROP SCHEMA IF EXISTS ingestion"
    execute "DROP SCHEMA IF EXISTS atlas"

    # The postgis extension is intentionally NOT dropped on rollback: it is a
    # database-wide resource that other schemas or extensions may depend on,
    # and dropping it would destroy every geometry column in the database.
    # Removing it, if ever needed, is a deliberate manual operation.
  end
end
