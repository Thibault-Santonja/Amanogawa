defmodule Amanogawa.Accounts.Session do
  @moduledoc """
  Cryptography and queries behind server-side sessions (issue #032):
  token generation, resolution, deletion, sliding renewal, and expiry
  purge. `Amanogawa.Accounts` is the only caller; nothing outside the
  Accounts context reaches this module. Mirrors `Amanogawa.Accounts.
  MagicLink`'s own shape.

  ## Security invariants

  * The clear token is `:crypto.strong_rand_bytes(32)`, URL-safe base64
    encoded (`Base.url_encode64/2`, no padding); it is returned to the
    caller once, at creation time, and never persisted anywhere.
  * Only `:crypto.hash(:sha256, clear_token)` is stored
    (`Amanogawa.Accounts.SessionToken`). A database leak yields no usable
    session.
  * A session is valid for 60 days (`validity_days/0`), checked in the
    resolution query itself (`inserted_at` compared against a threshold),
    not through a stored expiry column.
  * Sliding renewal: a session older than 7 days
    (`renewal_threshold_days/0`) is replaced by a fresh row (new token,
    new `inserted_at`) the next time it is resolved, in the same
    transaction the old row is deleted in
    (`Amanogawa.Accounts.renew_session_token/1`, called from
    `AmanogawaWeb.UserAuth.fetch_current_scope_for_user/2`); a session
    younger than that is left untouched, so an active user is never
    reissued a token on every single request.
  * Unlike a magic link token, a session token is repeatable (it
    authenticates every request until it expires or is revoked), so
    `get_user/1` never deletes the row it matched, and no URL-safe
    base64 pre-check is needed: any binary is hashed and compared as-is,
    an unknown or malformed value simply yields no match.
  """

  import Ecto.Query

  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Accounts.User
  alias Amanogawa.Repo

  # Security arbitration from issue #032 (F07 overview): 60 days balances
  # "stay signed in" convenience against exposure of a long-lived
  # credential; the 7-day sliding renewal threshold keeps an active
  # session's expiry always at least 53 days away without reissuing a
  # token on every request.
  @validity_days 60
  @renewal_threshold_days 7

  @token_bytes 32

  @doc "Validity window of a session token, in days."
  @spec validity_days() :: pos_integer()
  def validity_days, do: @validity_days

  @doc "Age, in days, past which a still-valid session is renewed."
  @spec renewal_threshold_days() :: pos_integer()
  def renewal_threshold_days, do: @renewal_threshold_days

  @doc """
  Creates a fresh session token for `user`.

  Returns `{:ok, {clear_token, session_token}}`: `clear_token` is the
  only place the plain value ever exists outside the caller's own
  memory, `session_token` the persisted (hash-only) row.
  """
  @spec create(User.t()) :: {:ok, {String.t(), SessionToken.t()}}
  def create(%User{id: user_id}) do
    clear_token = generate_clear_token()

    session_token =
      %SessionToken{}
      |> Ecto.Changeset.change(%{
        user_id: user_id,
        token_hash: hash(clear_token),
        inserted_at: utc_now()
      })
      |> Repo.insert!()

    {:ok, {clear_token, session_token}}
  end

  @doc """
  Resolves `clear_token` to its user, within the validity window.

  Never raises: an empty, malformed, or unknown token simply resolves to
  `nil`, exactly like an expired one.
  """
  @spec get_user(String.t()) :: User.t() | nil
  def get_user(clear_token) when is_binary(clear_token) do
    User
    |> join(:inner, [u], t in SessionToken, on: t.user_id == u.id)
    |> where([_u, t], t.token_hash == ^hash(clear_token) and t.inserted_at >= ^expiry_threshold())
    |> Repo.one()
  end

  def get_user(_clear_token), do: nil

  @doc """
  Deletes the row matching `clear_token`, if any. Idempotent: deleting an
  already-absent or unknown token is a silent no-op, never an error, so a
  double logout or a revoke racing an expiry purge never raises.
  """
  @spec delete(String.t()) :: :ok
  def delete(clear_token) when is_binary(clear_token) do
    SessionToken
    |> where([t], t.token_hash == ^hash(clear_token))
    |> Repo.delete_all()

    :ok
  end

  def delete(_clear_token), do: :ok

  @doc """
  Slides the session forward if `clear_token` resolves to a row older
  than `renewal_threshold_days/0`: deletes the old row and inserts a
  fresh one for the same user, in one transaction.

  Returns `{:ok, {new_clear_token, new_session_token}}` when renewed,
  `:unchanged` when the token is unknown or still recent (nothing to do).
  Only ever called after the caller has already established the token is
  currently valid (`get_user/1`); does not re-check the validity window
  itself.
  """
  @spec renew(String.t()) :: {:ok, {String.t(), SessionToken.t()}} | :unchanged
  def renew(clear_token) when is_binary(clear_token) do
    case get_row(clear_token) do
      nil -> :unchanged
      %SessionToken{} = old_token -> maybe_renew(old_token)
    end
  end

  def renew(_clear_token), do: :unchanged

  defp maybe_renew(%SessionToken{inserted_at: inserted_at} = old_token) do
    if DateTime.compare(inserted_at, renewal_threshold()) == :lt do
      replace(old_token)
    else
      :unchanged
    end
  end

  defp replace(old_token) do
    Repo.transaction(fn ->
      Repo.delete!(old_token)
      {:ok, {new_clear_token, new_token}} = create(%User{id: old_token.user_id})
      {new_clear_token, new_token}
    end)
  end

  @doc """
  Deletes every session token older than the validity window. Returns
  the number of rows deleted. Hygiene only (mirrors `Amanogawa.Accounts.
  MagicLink.purge_expired/0`): an expired session is already unusable by
  construction, the validity window is enforced in `get_user/1` itself.
  """
  @spec purge_expired() :: non_neg_integer()
  def purge_expired do
    {count, _} =
      SessionToken
      |> where([t], t.inserted_at < ^expiry_threshold())
      |> Repo.delete_all()

    count
  end

  @doc """
  Lists `user_id`'s active (within the validity window) sessions,
  newest first. Issue #033's account page: an expired session that has
  not been purged yet is never listed (no phantom sessions), and the
  returned structs still carry `token_hash` internally (never rendered
  by the web layer, `.claude/rules/security.md`) so
  `Amanogawa.Accounts.current_session_token?/2` can mark the current row.
  """
  @spec list_active(Ecto.UUID.t()) :: [SessionToken.t()]
  def list_active(user_id) do
    SessionToken
    |> where([t], t.user_id == ^user_id and t.inserted_at >= ^expiry_threshold())
    |> order_by([t], desc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Deletes the session `id` if, and only if, it belongs to `user_id`
  (IDOR check, `.claude/rules/security.md`): returns `:ok` when a row
  was actually deleted, `{:error, :not_found}` when `id` does not exist
  or belongs to someone else (a third party's session is left
  untouched, never revealed which case it was).
  """
  @spec revoke(String.t(), Ecto.UUID.t()) :: :ok | {:error, :not_found}
  def revoke(id, user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        SessionToken
        |> where([t], t.id == ^id and t.user_id == ^user_id)
        |> Repo.delete_all()
        |> case do
          {1, _} -> :ok
          {0, _} -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp get_row(clear_token) do
    SessionToken
    |> where([t], t.token_hash == ^hash(clear_token))
    |> Repo.one()
  end

  defp generate_clear_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash(clear_token), do: :crypto.hash(:sha256, clear_token)

  defp expiry_threshold, do: DateTime.add(utc_now(), -@validity_days, :day)

  defp renewal_threshold, do: DateTime.add(utc_now(), -@renewal_threshold_days, :day)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
