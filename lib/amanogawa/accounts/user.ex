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

  # Public pseudonym bounds (issue #034, F08 overview's "attribution
  # publique sans fuite d'email"): generous enough for a real display
  # name, small enough to keep the column and its case-insensitive unique
  # index cheap.
  @display_name_min_length 3
  @display_name_max_length 40

  # Minimal reserved-terms list (security review): a pseudonym is the
  # ONLY public identity in the contribution history, so one that
  # impersonates the moderation, the system, or the project itself would
  # lend false authority to its revisions. Matched after trimming,
  # downcasing and stripping accents, so casing or accent variants
  # ("Modérateur", "SYSTÈME") are caught too.
  @reserved_display_names ~w(relecteur reviewer moderateur moderator admin amanogawa systeme system)

  schema "users" do
    field :email, :string

    # Promoted manually in the database for V1 (issue #034, F08 overview:
    # "promue manuellement en base pour commencer"): no self-service
    # escalation path exists anywhere in this context.
    field :role, Ecto.Enum, values: [:user, :reviewer], default: :user

    # Public pseudonym (issue #034): required before a user's first
    # contribution proposal, never the email, which is never shown
    # publicly (`Amanogawa.Contributions`' revisions attribute by this
    # field alone).
    field :display_name, :string

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
  Builds and validates a changeset for `display_name` alone (issue #034,
  `Amanogawa.Accounts.set_display_name/2`): required, #{@display_name_min_length}
  to #{@display_name_max_length} characters, unique case-insensitively
  (`users_display_name_lower_index`, the same `lower(...)` technique
  `changeset/2` uses for `email`), and never one of the reserved
  moderation/system terms (`#{Enum.join(@reserved_display_names, ", ")}`,
  casing and accent variants included).
  """
  @spec display_name_changeset(t(), map()) :: Ecto.Changeset.t()
  def display_name_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name])
    |> validate_required([:display_name])
    |> validate_length(:display_name,
      min: @display_name_min_length,
      max: @display_name_max_length
    )
    |> validate_not_reserved(:display_name)
    |> unique_constraint(:display_name, name: :users_display_name_lower_index)
  end

  defp validate_not_reserved(changeset, field) do
    case get_change(changeset, field) do
      nil ->
        changeset

      value ->
        if normalize_for_reservation(value) in @reserved_display_names do
          add_error(changeset, field, "is reserved")
        else
          changeset
        end
    end
  end

  # Trim + downcase + strip combining accents (NFD decomposition), so
  # "Modérateur" and "SYSTÈME" normalize to their reserved base terms.
  defp normalize_for_reservation(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
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
