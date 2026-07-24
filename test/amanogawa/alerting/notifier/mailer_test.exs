defmodule Amanogawa.Alerting.Notifier.MailerTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Amanogawa.Alerting.Notifier.Mailer

  setup do
    original = Application.get_env(:amanogawa, Amanogawa.Alerting, [])

    Application.put_env(
      :amanogawa,
      Amanogawa.Alerting,
      Keyword.merge(original, from: "amanogawa@example.test", recipient: "ops@example.test")
    )

    on_exit(fn -> Application.put_env(:amanogawa, Amanogawa.Alerting, original) end)
  end

  test "builds and delivers an email with the configured from/recipient" do
    assert :ok = Mailer.deliver("subject line", "body text")

    assert_email_sent(
      subject: "subject line",
      text_body: "body text",
      to: [{"", "ops@example.test"}],
      from: {"", "amanogawa@example.test"}
    )
  end
end
