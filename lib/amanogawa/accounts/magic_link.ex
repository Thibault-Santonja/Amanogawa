defmodule Amanogawa.Accounts.MagicLink do
  @moduledoc """
  Cryptography and queries behind magic link tokens (issue #030): token
  generation, verification, and expiry purge. `Amanogawa.Accounts` is the
  only caller; nothing outside the Accounts context reaches this module.

  ## Security invariants

  * The clear token is `:crypto.strong_rand_bytes(32)`, URL-safe base64
    encoded (`Base.url_encode64/2`, no padding); it is returned to the
    caller once, at generation time, and never persisted anywhere.
  * Only `:crypto.hash(:sha256, clear_token)` is stored. A database leak
    yields no usable login link.
  * A token is valid for 15 minutes (`validity_minutes/0`), checked in
    the query itself (`inserted_at` compared against a threshold), not
    through a stored expiry column.
  * Requesting a new token for an email invalidates every existing token
    of that (normalized) email: `create/1` deletes before inserting, in
    one transaction.
  * A token is usage-once: `verify/1` deletes the row it matched in the
    same statement it matched it with (`DELETE ... RETURNING`, atomic in
    PostgreSQL), so a concurrent second verification of the same token
    finds no row left to consume.
  * `verify/1` never distinguishes *why* a token failed (unknown hash,
    expired, already consumed, malformed input): every failure is a
    plain `:error`, the anti-oracle property issue #031 relies on.
  """

  import Ecto.Query

  alias Amanogawa.Accounts.MagicLinkToken
  alias Amanogawa.Accounts.User
  alias Amanogawa.Repo

  # Security arbitration from the F07 overview, not runtime config: 15
  # minutes balances usability (enough time to open an email client) and
  # exposure (a leaked/intercepted link stops working quickly).
  @validity_minutes 15

  @token_bytes 32

  @doc "Validity window of a magic link token, in minutes."
  @spec validity_minutes() :: pos_integer()
  def validity_minutes, do: @validity_minutes

  @doc """
  Generates a fresh magic link token for `email` (any casing/whitespace,
  normalized here): in one transaction, deletes every existing token of
  the normalized email, then inserts a fresh one.

  Returns `{:ok, {clear_token, token}}`: `clear_token` is the only place
  the plain value ever exists outside the caller's own memory, `token`
  the persisted (hash-only) row.
  """
  @spec create(String.t()) :: {:ok, {String.t(), MagicLinkToken.t()}}
  def create(email) do
    normalized_email = User.normalize_email(email)
    clear_token = generate_clear_token()
    token_hash = hash(clear_token)

    {:ok, token} =
      Repo.transaction(fn ->
        invalidate_previous_tokens(normalized_email)

        %MagicLinkToken{}
        |> Ecto.Changeset.change(%{
          email: normalized_email,
          token_hash: token_hash,
          inserted_at: utc_now()
        })
        |> Repo.insert!()
      end)

    {:ok, {clear_token, token}}
  end

  @doc """
  Verifies and consumes `clear_token`.

  Rejects, as plain `:error`, without raising: a value that is not a
  binary, a binary that is not valid URL-safe base64, a well-formed but
  unknown token, and an expired or already-consumed token. On success,
  returns `{:ok, email}` with the normalized email the token was issued
  for, and the token row no longer exists.
  """
  @spec verify(String.t()) :: {:ok, String.t()} | :error
  def verify(clear_token) when is_binary(clear_token) do
    if url_safe_base64?(clear_token) do
      consume(clear_token)
    else
      :error
    end
  end

  def verify(_clear_token), do: :error

  @doc """
  Deletes every token older than the validity window. Returns the number
  of rows deleted. Hygiene only (see moduledoc): an expired token is
  already unusable by construction, this only keeps the table small.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    {count, _} =
      MagicLinkToken
      |> where([t], t.inserted_at < ^expiry_threshold())
      |> Repo.delete_all()

    count
  end

  defp invalidate_previous_tokens(normalized_email) do
    MagicLinkToken
    |> where([t], t.email == ^normalized_email)
    |> Repo.delete_all()
  end

  defp consume(clear_token) do
    query =
      MagicLinkToken
      |> where([t], t.token_hash == ^hash(clear_token) and t.inserted_at >= ^expiry_threshold())
      |> select([t], t.email)

    case Repo.delete_all(query) do
      {1, [email]} -> {:ok, email}
      {0, _} -> :error
    end
  end

  defp generate_clear_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash(clear_token), do: :crypto.hash(:sha256, clear_token)

  defp url_safe_base64?(value),
    do: match?({:ok, _decoded}, Base.url_decode64(value, padding: false))

  defp expiry_threshold, do: DateTime.add(utc_now(), -@validity_minutes, :minute)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
