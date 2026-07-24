defmodule Amanogawa.Accounts do
  @moduledoc """
  Public API of the Accounts bounded context: passwordless, magic-link
  authentication (issue #030, F07 overview's "pas de mot de passe, pas
  d'OAuth tiers"). Users hold nothing but an email and a creation date
  (ADR 0008 minimal data).

  Every other context and the entire web layer call this facade only,
  never `Amanogawa.Accounts.User`, `Amanogawa.Accounts.MagicLinkToken`,
  `Amanogawa.Accounts.MagicLink` or `Amanogawa.Repo` directly
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
    (issue #031). `deliver_magic_link/3` returns the exact same `:ok`
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

  `magic_link_url_fun` is a `(clear_token -> url)` function supplied by
  the web caller: this context never depends on the router (the same
  inversion `phx.gen.auth` uses).

  Returns `:ok` whether or not `email` already has an account
  (structural anti-enumeration, see the moduledoc) and even if the
  notifier itself fails to deliver (logged, never raised: the token
  stays valid, the caller can simply ask again, and requesting again
  invalidates it anyway). Returns `{:error, :rate_limited}` when either
  throttle counter is exhausted, `{:error, changeset}` when `email` is
  syntactically invalid (not a secret: safe to show back to a form).

  The locale used to render the email is read once, synchronously, from
  the calling process's own Gettext state
  (`Gettext.get_locale(AmanogawaWeb.Gettext)`, set for the current
  request by `AmanogawaWeb.Plugs.SetLocale`) and passed to the notifier
  as an explicit value: delivery itself never depends on the calling
  process past this point, so it stays correct even if delivery ever
  becomes asynchronous.
  """
  @spec deliver_magic_link(String.t(), String.t(), (String.t() -> String.t())) ::
          :ok | {:error, :rate_limited} | {:error, Ecto.Changeset.t()}
  def deliver_magic_link(email, ip, magic_link_url_fun) do
    case validate_email(email) do
      {:error, changeset} ->
        {:error, changeset}

      :ok ->
        if MagicLinkThrottle.allow?(ip, email) do
          send_magic_link(email, magic_link_url_fun)
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
  Deletes every magic link token older than the validity window.
  Returns the number of rows deleted. Called daily by
  `Amanogawa.Accounts.Workers.PurgeExpiredTokens` (Oban cron); hygiene
  only, see the moduledoc.
  """
  @spec purge_expired_magic_link_tokens() :: non_neg_integer()
  defdelegate purge_expired_magic_link_tokens, to: MagicLink, as: :purge_expired

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

  defp send_magic_link(email, magic_link_url_fun) do
    {:ok, {clear_token, _token}} = MagicLink.create(email)

    normalized_email = User.normalize_email(email)
    magic_link_url = magic_link_url_fun.(clear_token)
    locale = Gettext.get_locale(AmanogawaWeb.Gettext)

    case notifier().deliver(normalized_email, magic_link_url, locale) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("magic link delivery failed: #{inspect(reason)}")
        :ok
    end
  end

  defp notifier, do: Application.get_env(:amanogawa, :magic_link_notifier)
end
