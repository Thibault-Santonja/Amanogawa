defmodule Amanogawa.Repo.Migrations.CreateAccountsSessionTokens do
  use Ecto.Migration

  @moduledoc """
  Creates `accounts.session_tokens` (issue #032): the server-side,
  revocable session behind `Amanogawa.Accounts.Session` and
  `AmanogawaWeb.UserAuth`. The cookie carries only an opaque clear token;
  this table is what actually lets a session be revoked (deconnexion,
  revocation from the account page in #033, account deletion) by simply
  deleting the row.

  `on_delete: :delete_all` on the `user_id` foreign key (FK internal to
  the `accounts` schema, authorized by `.claude/rules/architecture.md`):
  deleting a user (issue #033's `delete_user/1`) cascades to every one of
  their sessions without a second query.
  """

  def change do
    create table(:session_tokens, primary_key: false, prefix: "accounts") do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users, type: :binary_id, prefix: "accounts", on_delete: :delete_all),
          null: false

      # SHA-256 of the clear session token; the clear token itself is
      # never persisted (`Amanogawa.Accounts.Session.create/1`), same
      # discipline as `accounts.magic_link_tokens.token_hash`.
      add :token_hash, :binary, null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:session_tokens, [:token_hash], prefix: "accounts")
    create index(:session_tokens, [:user_id], prefix: "accounts")
    # Purge of expired sessions (extends
    # Amanogawa.Accounts.Workers.PurgeExpiredTokens).
    create index(:session_tokens, [:inserted_at], prefix: "accounts")
  end
end
