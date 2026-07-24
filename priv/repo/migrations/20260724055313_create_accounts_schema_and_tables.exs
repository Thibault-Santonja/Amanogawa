defmodule Amanogawa.Repo.Migrations.CreateAccountsSchemaAndTables do
  use Ecto.Migration

  @moduledoc """
  Creates the `accounts` PostgreSQL schema and its two tables (issue #030,
  the fourth bounded context, `.claude/rules/architecture.md`): `users`
  (email-only, ADR 0008 minimal data) and `magic_link_tokens` (hash-only,
  usage-once magic link authentication, `Amanogawa.Accounts.MagicLink`).

  On the model of `20260723090000_create_postgis_and_schemas.exs`: the
  schema arrives with its context, `up`/`down` rather than `change` since
  schema creation/drop is not reversible by Ecto's DDL inference.
  """

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS accounts"

    create table(:users, primary_key: false, prefix: "accounts") do
      add :id, :binary_id, primary_key: true

      # Normalized (trimmed, downcased) by
      # `Amanogawa.Accounts.User.normalize_email/1` before it ever reaches
      # this column: the unique index below is what makes email uniqueness
      # case-insensitive without the `citext` extension.
      add :email, :string, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:users, [:email], prefix: "accounts")

    create table(:magic_link_tokens, primary_key: false, prefix: "accounts") do
      add :id, :binary_id, primary_key: true

      add :email, :string, null: false

      # SHA-256 of the clear token; the clear token itself is never
      # persisted (`Amanogawa.Accounts.MagicLink.create/1`).
      add :token_hash, :binary, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:magic_link_tokens, [:token_hash], prefix: "accounts")
    # Invalidation of a given email's previous tokens on a new request.
    create index(:magic_link_tokens, [:email], prefix: "accounts")
    # Purge of expired tokens (Amanogawa.Accounts.Workers.PurgeExpiredTokens).
    create index(:magic_link_tokens, [:inserted_at], prefix: "accounts")
  end

  def down do
    drop table(:magic_link_tokens, prefix: "accounts")
    drop table(:users, prefix: "accounts")

    execute "DROP SCHEMA IF EXISTS accounts"
  end
end
