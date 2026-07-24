defmodule Amanogawa.Accounts do
  @moduledoc """
  Public API of the Accounts bounded context: passwordless, magic-link
  authentication (issue #030, F07 overview's "pas de mot de passe, pas
  d'OAuth tiers"), server-side revocable sessions (#032), and the RGPD
  self-service of #033 (export, hard delete). Users hold nothing but an
  email and a creation date (ADR 0008 minimal data).

  Every other context and the entire web layer call this facade only,
  never `Amanogawa.Accounts.User`, `Amanogawa.Accounts.MagicLinkToken`,
  `Amanogawa.Accounts.MagicLink`, `Amanogawa.Accounts.SessionToken`,
  `Amanogawa.Accounts.Session` or `Amanogawa.Repo` directly
  (`.claude/rules/architecture.md`).

  ## Security invariants (#030, relied on by #031/#032 without being
  reinvented there)

  * **A magic link token is tied to an email, not a user.** The account
    is created (or found) only inside `redeem_magic_link_token/1`, at
    the moment a token is successfully verified, never when one is
    requested (`generate_magic_link_token/1`). An email with no account
    yet goes through the exact same code path as one that already has
    one: this is the structural anti-enumeration property issue #031
    builds its rate limiting and response shape on.
  * **The clear token never touches the database.** Only its SHA-256
    hash is stored (`Amanogawa.Accounts.MagicLinkToken`,
    `Amanogawa.Accounts.MagicLink`).
  * **Usage-once.** A token is deleted at the moment it is successfully
    verified, in the same statement that matched it, so a concurrent
    second use of the same clear token always fails.
  * **15-minute window**, enforced in the verification query, and every
    previous token of an email is invalidated the moment a new one is
    requested for it.
  * **Email is normalized once** (`Amanogawa.Accounts.User.
    normalize_email/1`): every read or write path in this context goes
    through it, so casing/whitespace never split one real address into
    two accounts or two token lineages.
  * **Anti-enumeration is structural, not a response-shaping trick**
    (issue #031). `deliver_magic_link/4` returns the exact same `:ok`
    whether or not `email` already has an account, hits the notifier
    exactly once either way, and a delivery failure is logged, never
    surfaced to the caller: the only externally distinguishable
    failures are a syntactically invalid email and a rate limit, never
    "this address is unknown".
  * **Rate limiting is double**, by IP and by normalized email
    independently (`Amanogawa.Accounts.MagicLinkThrottle`), both hit
    before a token is ever generated.
  """

  require Logger

  alias Amanogawa.Accounts.MagicLink
  alias Amanogawa.Accounts.MagicLinkThrottle
  alias Amanogawa.Accounts.MagicLinkToken
  alias Amanogawa.Accounts.Session
  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Accounts.User
  alias Amanogawa.Repo

  @doc """
  Generates a fresh magic link token for `email`.

  Returns `{:ok, {clear_token, token}}` on a syntactically valid email
  (an unregistered email is not an error: see the moduledoc's
  anti-enumeration invariant), `{:error, changeset}` when the email
  itself is malformed. Never creates a user: see
  `redeem_magic_link_token/1`.
  """
  @spec generate_magic_link_token(String.t()) ::
          {:ok, {String.t(), MagicLinkToken.t()}} | {:error, Ecto.Changeset.t()}
  def generate_magic_link_token(email) do
    case validate_email(email) do
      :ok -> MagicLink.create(email)
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Redeems a clear magic link token: verifies and consumes it
  (`Amanogawa.Accounts.MagicLink.verify/1`), then gets or creates the
  user for the email it was issued to, in the same transaction.

  Returns `{:ok, user}` on success, `:error` for every failure case
  (unknown, expired, already-consumed, or malformed token), never
  distinguishing which: see the moduledoc's anti-oracle invariant.

  The get-or-create step is an idempotent upsert (`on_conflict:
  :nothing` on the unique email index, followed by a re-read): a race
  between two redemptions that both resolve to the same email (for
  example two tabs opening the same still-valid link a moment apart, or
  two never-linked concurrent requests) never raises a unique constraint
  error and never creates two rows for one email.
  """
  @spec redeem_magic_link_token(String.t()) :: {:ok, User.t()} | :error
  def redeem_magic_link_token(clear_token) do
    Repo.transaction(fn ->
      case MagicLink.verify(clear_token) do
        {:ok, email} -> get_or_create_user(email)
        :error -> Repo.rollback(:error)
      end
    end)
    |> case do
      {:ok, user} -> {:ok, user}
      {:error, :error} -> :error
    end
  end

  @doc """
  Requests a magic link for `email` from client `ip`: validates and
  normalizes the email, throttles (`Amanogawa.Accounts.
  MagicLinkThrottle.allow?/2`, IP and email independently), generates a
  token (`Amanogawa.Accounts.MagicLink.create/1`), and delivers it
  through the configured `Amanogawa.Accounts.MagicLinkNotifier`
  (`Application.get_env(:amanogawa, :magic_link_notifier)`, a Mox mock
  in test).

  `locale` is the locale the email is rendered in, passed as an explicit
  value by the web caller (which owns locale resolution,
  `AmanogawaWeb.Plugs.SetLocale` / `AmanogawaWeb.LoginLive`): this
  domain context never reads the web layer's Gettext state, and delivery
  never depends on the calling process's own locale, so it stays correct
  even if delivery ever becomes asynchronous. `magic_link_url_fun` is a
  `(clear_token -> url)` function supplied by the web caller for the
  same reason: this context never depends on the router (the same
  inversion `phx.gen.auth` uses).

  Returns `:ok` whether or not `email` already has an account
  (structural anti-enumeration, see the moduledoc) and even if the
  notifier itself fails to deliver (logged, never raised: the token
  stays valid, the caller can simply ask again, and requesting again
  invalidates it anyway). Returns `{:error, :rate_limited}` when either
  throttle counter is exhausted, `{:error, changeset}` when `email` is
  syntactically invalid (not a secret: safe to show back to a form).
  """
  @spec deliver_magic_link(String.t(), String.t(), String.t(), (String.t() -> String.t())) ::
          :ok | {:error, :rate_limited} | {:error, Ecto.Changeset.t()}
  def deliver_magic_link(email, ip, locale, magic_link_url_fun) do
    case validate_email(email) do
      {:error, changeset} ->
        {:error, changeset}

      :ok ->
        if MagicLinkThrottle.allow?(ip, email) do
          send_magic_link(email, locale, magic_link_url_fun)
        else
          {:error, :rate_limited}
        end
    end
  end

  @doc "Fetches a user by id, raising if none exists."
  @spec get_user!(Ecto.UUID.t()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  @doc "Fetches a user by email (normalized before lookup), or `nil`."
  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email), do: Repo.get_by(User, email: User.normalize_email(email))

  @doc """
  Normalizes an email exactly the way this context stores and looks one
  up (`Amanogawa.Accounts.User.normalize_email/1`: trim, downcase).
  Exposed on the facade so the web layer can compare a user-typed email
  against an account's (issue #033's deletion confirmation) with the
  same normalization the domain applies, without reaching the internal
  `User` module (`.claude/rules/architecture.md`).
  """
  @spec normalize_email(String.t()) :: String.t()
  defdelegate normalize_email(email), to: User

  @doc """
  Creates a server-side session for `user` (issue #032,
  `Amanogawa.Accounts.Session`): returns `{:ok, {clear_token,
  session_token}}`, the clear token to store in the caller's cookie, the
  persisted (hash-only) row otherwise. Called once, from
  `AmanogawaWeb.UserAuth.log_in_user/2`.
  """
  @spec create_session_token(User.t()) :: {:ok, {String.t(), SessionToken.t()}}
  defdelegate create_session_token(user), to: Session, as: :create

  @doc """
  Resolves a clear session token to its user, within the 60-day validity
  window (`Amanogawa.Accounts.Session`). Never raises: an altered,
  empty, unknown, or expired token resolves to `nil`.
  """
  @spec get_user_by_session_token(String.t()) :: User.t() | nil
  defdelegate get_user_by_session_token(clear_token), to: Session, as: :get_user

  @doc """
  Resolves a clear session token to its user AND the session token row
  it matched, within the 60-day validity window, in one query
  (`Amanogawa.Accounts.Session.get_user_and_token/1`). The returned row
  is what `renew_session_token/1` takes, so the caller
  (`AmanogawaWeb.UserAuth.fetch_current_scope_for_user/2`) never needs a
  second lookup to decide about sliding renewal. Never raises: an
  altered, empty, unknown, or expired token resolves to `nil`.
  """
  @spec get_user_and_session_token(String.t()) :: {User.t(), SessionToken.t()} | nil
  defdelegate get_user_and_session_token(clear_token), to: Session, as: :get_user_and_token

  @doc """
  Deletes the session matching `clear_token`, if any (server-side
  revocation: logout, or the account-page revocation of #033).
  Idempotent.
  """
  @spec delete_session_token(String.t()) :: :ok
  defdelegate delete_session_token(clear_token), to: Session, as: :delete

  @doc """
  Slides a session forward if the already-resolved row
  (`get_user_and_session_token/1`) is older than 7 days (`Amanogawa.
  Accounts.Session.renewal_threshold_days/0`): returns `{:ok,
  {new_clear_token, new_session_token}}` when renewed, `:unchanged`
  otherwise (still recent, already expired, or concurrently renewed:
  the replacement is atomic, see `Amanogawa.Accounts.Session.renew/1`).
  Called from `AmanogawaWeb.UserAuth.fetch_current_scope_for_user/2` on
  every authenticated request.
  """
  @spec renew_session_token(SessionToken.t()) ::
          {:ok, {String.t(), SessionToken.t()}} | :unchanged
  defdelegate renew_session_token(session_token), to: Session, as: :renew

  @doc """
  `true` when `clear_token` is the one `session_token` was created from,
  determined by re-hashing `clear_token` and comparing
  (`Plug.Crypto.secure_compare/2`, non-oracular) against the persisted
  `token_hash`: the mechanism `AmanogawaWeb.AccountLive` (#033) uses to
  mark the "current session" row in a session list without this facade
  ever handing a hash to the web layer to compare itself.
  """
  @spec current_session_token?(SessionToken.t(), String.t()) :: boolean()
  def current_session_token?(%SessionToken{} = session_token, clear_token)
      when is_binary(clear_token) do
    Plug.Crypto.secure_compare(session_token.token_hash, :crypto.hash(:sha256, clear_token))
  end

  @doc """
  Deletes every magic link and session token older than their respective
  validity windows. Returns the total number of rows deleted. Called
  daily by `Amanogawa.Accounts.Workers.PurgeExpiredTokens` (Oban cron);
  hygiene only, see the moduledocs of `Amanogawa.Accounts.MagicLink` and
  `Amanogawa.Accounts.Session`.
  """
  @spec purge_expired_tokens() :: non_neg_integer()
  def purge_expired_tokens do
    MagicLink.purge_expired() + Session.purge_expired()
  end

  @doc """
  Lists `user.id`'s active sessions, newest first (issue #033's account
  page). Never includes an already-expired session: `Amanogawa.Accounts.
  Session.list_active/1` applies the same 60-day window `get_user_by_
  session_token/1` does.
  """
  @spec list_session_tokens(User.t()) :: [SessionToken.t()]
  def list_session_tokens(%User{id: user_id}), do: Session.list_active(user_id)

  @doc """
  Revokes session `id` for `user`: deletes the row only if it belongs to
  `user` (IDOR check, `.claude/rules/security.md`, verified before this
  mutation): `:ok` on success, `{:error, :not_found}` for an unknown id
  or one owned by another user (the two cases are never distinguished,
  same anti-oracle spirit as the rest of this context).

  Does not itself disconnect a live socket for the revoked session: the
  web layer (`AmanogawaWeb.AccountLive`) does, since the
  `"users_sessions:<id>"` broadcast topic is a web-layer convention
  (`AmanogawaWeb.UserAuth`), not a domain concern.
  """
  @spec revoke_session_token(User.t(), String.t()) :: :ok | {:error, :not_found}
  def revoke_session_token(%User{id: user_id}, id), do: Session.revoke(id, user_id)

  @doc """
  A versioned, serializable map of everything the database knows about
  `user` (issue #033, RGPD article 20 portability): `%{format_version:
  1, exported_at: ..., account: %{email:, inserted_at:}, sessions: [%{
  inserted_at:}, ...], pending_magic_link: %{requested_at:} | nil}`.

  `pending_magic_link` carries the request date of the still-valid
  (15-minute window) magic link token issued for the user's email, or
  `nil` when none is pending: a pending sign-in request is data the
  database holds about this person, so the export must surface it.

  Never includes a `token_hash` or a clear token, in the account, the
  sessions list, or the pending magic link entry: an export is a right
  the user exercises on themselves, but a credential is still not "data
  about the account" in the sense this key means. `format_version`
  exists so F08 can add a `contributions` key later without breaking a
  consumer that already parsed an export under this shape.
  """
  @spec export_user_data(User.t()) :: map()
  def export_user_data(%User{} = user) do
    %{
      format_version: 1,
      exported_at: DateTime.utc_now(),
      account: %{email: user.email, inserted_at: user.inserted_at},
      sessions: Enum.map(list_session_tokens(user), &%{inserted_at: &1.inserted_at}),
      pending_magic_link: pending_magic_link(user.email)
    }
  end

  @doc """
  Hard-deletes `user`: their magic link tokens (matched by email, since
  those are not foreign-keyed to the user row, see `Amanogawa.Accounts.
  MagicLinkToken`), then the user row itself, in one transaction; session
  tokens are removed by the `on_delete: :delete_all` foreign key rather
  than a third explicit query. Returns `:ok`.

  No soft delete, no `deleted_at`, no retention (issue #033, ADR 0008):
  after this returns, the email can sign up again as a brand new
  account. This is the single point where F08's future ADR on
  contribution attribution after account deletion will need to insert
  itself (pseudonymization, most likely): today there is nothing to
  attribute yet, so there is nothing else to arbitrate here.

  Idempotent: a concurrent second deletion of the same account (a
  double click, or two tabs both confirming, issue #033's own point
  d'attention) finds the row already gone (`stale_error_field: :id`
  turns what would otherwise be a raised `Ecto.StaleEntryError` into a
  no-op) and still returns `:ok`, never a crash.
  """
  @spec delete_user(User.t()) :: :ok
  def delete_user(%User{} = user) do
    Repo.transaction(fn ->
      MagicLink.delete_all_for_email(user.email)
      Repo.delete(user, stale_error_field: :id)
    end)

    :ok
  end

  defp pending_magic_link(email) do
    case MagicLink.pending_request_at(email) do
      nil -> nil
      requested_at -> %{requested_at: requested_at}
    end
  end

  defp validate_email(email) do
    changeset = User.changeset(%User{}, %{email: email})

    if changeset.valid?, do: :ok, else: {:error, changeset}
  end

  defp get_or_create_user(email) do
    %User{}
    |> User.changeset(%{email: email})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: :email)

    Repo.get_by!(User, email: email)
  end

  defp send_magic_link(email, locale, magic_link_url_fun) do
    {:ok, {clear_token, _token}} = MagicLink.create(email)

    normalized_email = User.normalize_email(email)
    magic_link_url = magic_link_url_fun.(clear_token)

    case notifier().deliver(normalized_email, magic_link_url, locale) do
      :ok ->
        :ok

      {:error, reason} ->
        # Bounded tag only, never `inspect(reason)`: an SMTP error reason
        # can embed the whole outgoing message (recipient email, magic
        # link URL), which must never reach the logs.
        Logger.error("magic link delivery failed: #{delivery_error_tag(reason)}")
        :ok
    end
  end

  # Reduces an arbitrary notifier error reason to a bounded, safe tag: an
  # atom is logged as-is, an exception by its module name, anything else
  # (tuples, binaries, whole SMTP transcripts) as an opaque marker.
  defp delivery_error_tag(reason) when is_atom(reason), do: inspect(reason)
  defp delivery_error_tag(%struct{}), do: inspect(struct)
  defp delivery_error_tag(_reason), do: "unexpected error"

  defp notifier, do: Application.get_env(:amanogawa, :magic_link_notifier)
end
