defmodule Amanogawa.Mailer do
  @moduledoc """
  Swoosh mailer (issue #028): sends through the VPS's own local SMTP
  relay (`config :amanogawa, Amanogawa.Mailer` in `config/runtime.exs`,
  the same relay already used by the other projects on this host,
  `.claude/memory/tech-stack.md`), never a third-party transactional
  email service. The only current caller is
  `Amanogawa.Alerting.Notifier.Mailer`; this module has no other reason
  to exist yet (no user-facing email in phase 1).
  """

  use Swoosh.Mailer, otp_app: :amanogawa
end
