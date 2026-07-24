defmodule Amanogawa.Accounts.MagicLinkNotifier.MailerTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Amanogawa.Accounts.MagicLinkNotifier.Mailer

  @magic_link_url "https://amanogawa.example/connexion/abc123"

  setup do
    original = Application.get_env(:amanogawa, Amanogawa.Accounts, [])

    Application.put_env(
      :amanogawa,
      Amanogawa.Accounts,
      Keyword.merge(original, from: "connexion@example.test")
    )

    on_exit(fn -> Application.put_env(:amanogawa, Amanogawa.Accounts, original) end)
  end

  test "delivers a plain-text, French email to the given recipient" do
    assert :ok = Mailer.deliver("person@example.com", @magic_link_url, "fr")

    assert_email_sent(fn email ->
      assert email.subject == "Votre lien de connexion Amanogawa"
      assert email.to == [{"", "person@example.com"}]
      assert email.from == {"", "connexion@example.test"}
      assert email.text_body =~ @magic_link_url
      assert email.text_body =~ "15 minutes"
      assert email.text_body =~ "une seule fois"
      assert email.html_body == nil
    end)
  end

  test "delivers in English for locale \"en\"" do
    assert :ok = Mailer.deliver("person@example.com", @magic_link_url, "en")

    assert_email_sent(fn email ->
      assert email.subject == "Your Amanogawa sign-in link"
      assert email.text_body =~ @magic_link_url
      assert email.text_body =~ "15 minutes"
      assert email.text_body =~ "once"
    end)
  end

  test "an unrecognized locale still renders (Gettext's own missing-translation fallback returns the French source text)" do
    assert :ok = Mailer.deliver("person@example.com", @magic_link_url, "xx")

    assert_email_sent(subject: "Votre lien de connexion Amanogawa")
  end
end
