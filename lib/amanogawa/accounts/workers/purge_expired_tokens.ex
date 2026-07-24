defmodule Amanogawa.Accounts.Workers.PurgeExpiredTokens do
  @moduledoc """
  Oban Cron entry point for the daily magic link token purge (issue
  #030, `config/config.exs`'s `Oban.Plugins.Cron` crontab): delegates to
  `Amanogawa.Accounts.purge_expired_magic_link_tokens/0`, never
  `Amanogawa.Accounts.MagicLink` or `Amanogawa.Repo` directly (the
  facade is the only door, `.claude/rules/architecture.md`).

  Hygiene, not security (see `Amanogawa.Accounts.MagicLink`'s own
  moduledoc): an expired token is already unusable by construction, the
  validity window is enforced in the verification query itself. Leaving
  this cron disabled or failing for a while would grow the table, never
  weaken the security guarantee.
  """

  use Oban.Worker, queue: :accounts, max_attempts: 3

  alias Amanogawa.Accounts

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{}) do
    Accounts.purge_expired_magic_link_tokens()
    :ok
  end
end
