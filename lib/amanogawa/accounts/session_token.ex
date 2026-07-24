defmodule Amanogawa.Accounts.SessionToken do
  @moduledoc """
  A server-side session: ties a user to the SHA-256 hash of an opaque,
  60-day, slidingly-renewed session token (issue #032,
  `Amanogawa.Accounts.Session`). The clear token itself never reaches
  this schema, let alone the database: only its hash does, on the exact
  model of `Amanogawa.Accounts.MagicLinkToken`.

  Immutable (no `updated_at`): a row is inserted once, then either
  deleted (logout, revocation from the account page in #033, account
  deletion cascading through `user_id`'s `on_delete: :delete_all`, or
  superseded by a fresh row on sliding renewal) or purged once expired
  (`Amanogawa.Accounts.Workers.PurgeExpiredTokens`).

  `token_hash` is `redact: true` so it never appears in a `Logger` call, a
  changeset error, or an `IO.inspect/2` of this struct.

  Internal to the Accounts context: only `Amanogawa.Accounts` is called
  from other contexts or from the web layer. Web callers receive this
  struct across the facade boundary (`list_session_tokens/1`) but must
  never render `token_hash` to a client (`.claude/rules/security.md`,
  issue #033).
  """

  use Ecto.Schema

  alias Amanogawa.Accounts.User

  @type t :: %__MODULE__{}

  @schema_prefix "accounts"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "session_tokens" do
    field :token_hash, :binary, redact: true
    belongs_to :user, User, type: Ecto.UUID

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
