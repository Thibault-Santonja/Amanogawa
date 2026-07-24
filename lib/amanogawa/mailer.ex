defmodule Amanogawa.Mailer do
  @moduledoc """
  Swoosh mailer (issue #028): sends through the VPS's own local SMTP
  relay (`config :amanogawa, Amanogawa.Mailer` in `config/runtime.exs`,
  the same relay already used by the other projects on this host,
  `.claude/memory/tech-stack.md`), never a third-party transactional
  email service. Two callers share it: `Amanogawa.Alerting.Notifier.
  Mailer` (operator alerts, issue #028) and, since issue #031,
  `Amanogawa.Accounts.MagicLinkNotifier.Mailer` (user-facing magic link
  sign-in emails, the first user-facing email this project sends).
  """

  use Swoosh.Mailer, otp_app: :amanogawa
end
