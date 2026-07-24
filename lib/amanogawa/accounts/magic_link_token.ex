defmodule Amanogawa.Accounts.MagicLinkToken do
  @moduledoc """
  A magic link token: ties a normalized email to the SHA-256 hash of a
  single-use, 15-minute clear token (issue #030,
  `Amanogawa.Accounts.MagicLink`). The clear token itself never reaches
  this schema, let alone the database: only its hash does.

  Immutable (no `updated_at`): a row is inserted once, then either
  deleted on successful verification (usage-once) or purged once expired
  (`Amanogawa.Accounts.Workers.PurgeExpiredTokens`). It is never updated
  in place.

  `token_hash` is `redact: true` so it never appears in a `Logger` call, a
  changeset error, or an `IO.inspect/2` of this struct
  (`Inspect.Algebra`/`Ecto.Schema`'s own auto-derived `Inspect`, the same
  mechanism phx.gen.auth uses to redact a hashed password).

  Internal to the Accounts context: only `Amanogawa.Accounts` is called
  from other contexts or from the web layer.
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}

  @schema_prefix "accounts"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "magic_link_tokens" do
    field :email, :string
    field :token_hash, :binary, redact: true

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
