defmodule Amanogawa.Accounts.MagicLinkNotifier do
  @moduledoc """
  Port for delivering a magic link email (issue #031): `Amanogawa.
  Accounts.deliver_magic_link/3` depends on this behaviour only, never on
  `Amanogawa.Mailer` or Swoosh directly, so it stays testable with Mox
  (`Amanogawa.MagicLinkNotifierMock`, `test/support/mocks.ex`) exactly
  like every other outbound port in this codebase (mirrors `Amanogawa.
  Alerting.Notifier`).

  No transport concern (SMTP, Swoosh's own types) crosses this boundary:
  the domain calls `deliver/3` with plain strings and gets back `:ok` or
  a tagged error.
  """

  @doc """
  Delivers the magic link email for `magic_link_url` to `email`, rendered
  in `locale` (`"fr"` or `"en"`, a parameter rather than the caller
  process's own Gettext locale: delivery can run asynchronously, and the
  locale must survive that).

  Returns `:ok` on success, `{:error, reason}` otherwise; the caller
  (`Amanogawa.Accounts.deliver_magic_link/3`) never lets a delivery
  failure crash or reveal more than a generic outcome to the requester
  (anti-enumeration, F07 overview).
  """
  @callback deliver(email :: String.t(), magic_link_url :: String.t(), locale :: String.t()) ::
              :ok | {:error, term()}
end
