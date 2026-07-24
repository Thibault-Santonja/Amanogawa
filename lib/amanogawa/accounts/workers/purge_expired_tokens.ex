defmodule Amanogawa.Accounts.Workers.PurgeExpiredTokens do
  @moduledoc """
  Oban Cron entry point for the daily magic link and session token purge
  (issue #030, extended to session tokens in #032,
  `config/config.exs`'s `Oban.Plugins.Cron` crontab): delegates to
  `Amanogawa.Accounts.purge_expired_tokens/0`, never `Amanogawa.Accounts.
  MagicLink`, `Amanogawa.Accounts.Session`, or `Amanogawa.Repo` directly
  (the facade is the only door, `.claude/rules/architecture.md`).

  Hygiene, not security (see the moduledocs of `Amanogawa.Accounts.
  MagicLink` and `Amanogawa.Accounts.Session`): an expired token of
  either kind is already unusable by construction, both validity windows
  are enforced in their own verification/resolution queries. Leaving
  this cron disabled or failing for a while would grow the tables, never
  weaken the security guarantee.
  """

  use Oban.Worker, queue: :accounts, max_attempts: 3

  alias Amanogawa.Accounts

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    Accounts.purge_expired_tokens()
    :ok
  end
end
