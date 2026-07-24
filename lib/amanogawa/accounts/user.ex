defmodule Amanogawa.Accounts.User do
  @moduledoc """
  A user account: an email and a creation date, nothing else (issue #030,
  ADR 0008 minimal data). No password is ever stored, no third-party
  identity is ever linked.

  A row is created (or found) only at the moment a magic link is
  successfully redeemed (`Amanogawa.Accounts.redeem_magic_link_token/1`),
  never when a link is merely requested: the email is verified by
  construction before any account exists.

  Internal to the Accounts context: only `Amanogawa.Accounts` is called
  from other contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @schema_prefix "accounts"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  # Same bound as phx.gen.auth's own `users` schema: generous enough for
  # any real address, small enough to keep the column and its index cheap.
  @max_email_length 160

  # Deliberately permissive (presence of a single `@`, no whitespace): an
  # over-restrictive email regex rejects real addresses more often than it
  # catches anything meaningful, and the only source of truth for whether
  # an address works is the magic link actually being delivered to it.
  @email_format ~r/\A[^\s]+@[^\s]+\z/

  schema "users" do
    field :email, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds and validates a changeset for a user.

  `email` is normalized (`normalize_email/1`) before every validation, so
  the required/format/length checks and the unique constraint all apply
  to the value that is actually persisted.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email])
    |> validate_format(:email, @email_format, message: "must be a valid email address")
    |> validate_length(:email, max: @max_email_length)
    |> unique_constraint(:email)
  end

  @doc """
  Normalizes an email for storage, lookup, and token generation: trims
  surrounding whitespace and downcases it. Every entry point of the
  Accounts context that reads or writes an email (`changeset/2`,
  `Amanogawa.Accounts.MagicLink.create/1`,
  `Amanogawa.Accounts.get_user_by_email/1`) goes through this exact
  function, so `User@Example.com` and `user@example.com ` always resolve
  to the same account.

  Idempotent: normalizing an already-normalized email is a no-op.

  ## Examples

      iex> Amanogawa.Accounts.User.normalize_email("  User@Example.COM  ")
      "user@example.com"

      iex> Amanogawa.Accounts.User.normalize_email("user@example.com")
      "user@example.com"

  """
  @spec normalize_email(String.t()) :: String.t()
  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end
end
