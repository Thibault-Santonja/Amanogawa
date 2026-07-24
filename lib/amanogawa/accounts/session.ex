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
    new `inserted_at`) the next time it is resolved. The caller resolves
    first (`get_user_and_token/1`, which returns the matched row so no
    second lookup is ever needed) and only then calls `renew/1` with
    that row; `renew/1` itself re-checks the validity window in its
    delete (defense in depth): an expired session can never be
    resurrected into a fresh one, even by a caller that skipped the
    resolution step. A session younger than the threshold is left
    untouched, so an active user is never reissued a token on every
    single request.
  * The replacement inside `renew/1` is atomic on the old row: the
    delete is keyed on the row id AND the validity window, and the fresh
    row is only inserted when that delete actually removed a row
    (`{1, _}`). Two concurrent renewals of the same session therefore
    never raise (no `Ecto.StaleEntryError`) and never mint two
    replacement tokens: exactly one wins, the other observes `{0, _}`
    and reports `:unchanged`.
  * Unlike a magic link token, a session token is repeatable (it
    authenticates every request until it expires or is revoked), so
    `get_user/1` never deletes the row it matched, and no URL-safe
    base64 pre-check is needed: any binary is hashed and compared as-is,
    an unknown or malformed value simply yields no match.

  ## No absolute session lifetime cap (assumed arbitration)

  Sliding renewal means a session that is used at least once every 60
  days never expires: there is deliberately no absolute cap on total
  session age (some deployments cap at 90 days or a year regardless of
  activity). Arbitration from issue #032: for a service holding nothing
  but an email, forcing a periodic re-login costs more (a magic link
  email round trip) than it protects, and a stolen cookie is detected
  through invalidation instead: every renewal invalidates the previous
  token, so a legitimate client and a thief cannot both keep renewing
  the same lineage, whichever presents the stale token first is logged
  out, and the account page (#033) lists and revokes active sessions.
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
  def get_user(clear_token) do
    case get_user_and_token(clear_token) do
      {user, _session_token} -> user
      nil -> nil
    end
  end

  @doc """
  Resolves `clear_token` to its user AND the session token row it
  matched, within the validity window, in one query.

  The returned row is what lets the caller decide about sliding renewal
  (`renew/1` takes it directly) without a second lookup: this pair is
  the whole per-navigation database cost of authentication
  (`AmanogawaWeb.UserAuth.fetch_current_scope_for_user/2`).

  Never raises: an empty, malformed, unknown, or expired token resolves
  to `nil`.
  """
  @spec get_user_and_token(String.t()) :: {User.t(), SessionToken.t()} | nil
  def get_user_and_token(clear_token) when is_binary(clear_token) do
    User
    |> join(:inner, [u], t in SessionToken, on: t.user_id == u.id)
    |> where([_u, t], t.token_hash == ^hash(clear_token) and t.inserted_at >= ^expiry_threshold())
    |> select([u, t], {u, t})
    |> Repo.one()
  end

  def get_user_and_token(_clear_token), do: nil

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
  Slides the session forward if `session_token` (the row already
  resolved by `get_user_and_token/1`, never re-fetched here) is older
  than `renewal_threshold_days/0`: atomically deletes the old row and
  inserts a fresh one for the same user.

  Returns `{:ok, {new_clear_token, new_session_token}}` when renewed,
  `:unchanged` when the row is still recent, already expired, or already
  gone. The delete is keyed on the row id AND the validity window
  (defense in depth: an expired row is never replaced by a fresh one,
  regardless of what the caller resolved), and the fresh row is only
  created when the delete removed exactly one row, so two concurrent
  renewals of the same session never raise and never both mint a token.
  """
  @spec renew(SessionToken.t()) :: {:ok, {String.t(), SessionToken.t()}} | :unchanged
  def renew(%SessionToken{inserted_at: inserted_at} = session_token) do
    if DateTime.compare(inserted_at, renewal_threshold()) == :lt do
      replace(session_token)
    else
      :unchanged
    end
  end

  # The delete and the insert share one transaction so a crash between
  # them cannot leave the user without any session row; the {1, _} guard
  # is what serializes concurrent renewals (the loser's delete matches
  # zero rows once the winner's transaction commits).
  defp replace(%SessionToken{id: id, user_id: user_id}) do
    {:ok, result} =
      Repo.transaction(fn ->
        SessionToken
        |> where([t], t.id == ^id and t.inserted_at >= ^expiry_threshold())
        |> Repo.delete_all()
        |> case do
          {1, _} ->
            {:ok, {new_clear_token, new_token}} = create(%User{id: user_id})
            {:ok, {new_clear_token, new_token}}

          {0, _} ->
            :unchanged
        end
      end)

    result
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

  defp generate_clear_token do
    @token_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp hash(clear_token), do: :crypto.hash(:sha256, clear_token)

  defp expiry_threshold, do: DateTime.add(utc_now(), -@validity_days, :day)

  defp renewal_threshold, do: DateTime.add(utc_now(), -@renewal_threshold_days, :day)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
