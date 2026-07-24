defmodule Amanogawa.Accounts.MagicLinkDeliveryTest do
  @moduledoc """
  Integration test for `Amanogawa.Accounts.deliver_magic_link/3` through
  the real `Amanogawa.Accounts.MagicLinkNotifier.Mailer` adapter (issue
  #031's own "chaîne complète avec l'adaptateur Swoosh réel"), instead of
  `Amanogawa.MagicLinkNotifierMock` (`config/test.exs`'s default). Kept
  in its own module, `async: false`, because it temporarily overrides the
  global `:magic_link_notifier` application env: unsafe to run alongside
  other async tests reading the same key.
  """

  use Amanogawa.DataCase, async: false

  import Swoosh.TestAssertions

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.MagicLinkNotifier.Mailer
  alias Amanogawa.Accounts.User

  setup do
    original = Application.get_env(:amanogawa, :magic_link_notifier)
    Application.put_env(:amanogawa, :magic_link_notifier, Mailer)
    on_exit(fn -> Application.put_env(:amanogawa, :magic_link_notifier, original) end)
  end

  test "the URL captured from the real delivered email authenticates its issuing email" do
    email = "person-#{System.unique_integer([:positive])}@example.com"

    assert :ok =
             Accounts.deliver_magic_link(email, "10.0.0.1", fn token ->
               "https://amanogawa.example/connexion/#{token}"
             end)

    assert_email_sent(fn sent_email ->
      [url] = Regex.run(~r{https://amanogawa\.example/connexion/\S+}, sent_email.text_body)

      token = String.replace_prefix(url, "https://amanogawa.example/connexion/", "")

      assert {:ok, %User{email: normalized_email}} = Accounts.redeem_magic_link_token(token)
      assert normalized_email == User.normalize_email(email)
    end)
  end
end
