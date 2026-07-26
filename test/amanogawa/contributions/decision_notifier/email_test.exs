defmodule Amanogawa.Contributions.DecisionNotifier.EmailTest do
  use ExUnit.Case, async: false

  import Swoosh.TestAssertions

  alias Amanogawa.Contributions.DecisionNotifier.Email

  @contribution_path "/contributions/019f9f87-0000-7000-8000-000000000000"

  setup do
    original = Application.get_env(:amanogawa, Amanogawa.Accounts, [])

    Application.put_env(
      :amanogawa,
      Amanogawa.Accounts,
      Keyword.merge(original, from: "connexion@example.test")
    )

    on_exit(fn -> Application.put_env(:amanogawa, Amanogawa.Accounts, original) end)
  end

  test "accepted: a plain-text, French email with the motive and an absolute link" do
    assert :ok =
             Email.deliver(
               "person@example.com",
               :accepted,
               "Source fiable",
               @contribution_path,
               "fr"
             )

    assert_email_sent(fn email ->
      assert email.subject == "Votre proposition a été acceptée"
      assert email.to == [{"", "person@example.com"}]
      assert email.from == {"", "connexion@example.test"}
      assert email.text_body =~ "Source fiable"
      assert email.text_body =~ @contribution_path
      assert email.text_body =~ "http"
      assert email.html_body == nil
    end)
  end

  test "rejected: includes the motive and mentions the possible appeal" do
    assert :ok =
             Email.deliver(
               "person@example.com",
               :rejected,
               "Source insuffisante",
               @contribution_path,
               "fr"
             )

    assert_email_sent(fn email ->
      assert email.subject == "Votre proposition a été rejetée"
      assert email.text_body =~ "Source insuffisante"
    end)
  end

  test "appeal_accepted: distinct subject and body" do
    assert :ok =
             Email.deliver("person@example.com", :appeal_accepted, "Vu", @contribution_path, "fr")

    assert_email_sent(fn email ->
      assert email.subject == "Votre appel a été accepté"
      assert email.text_body =~ "Vu"
    end)
  end

  test "appeal_rejected: distinct subject and body, decision framed as final" do
    assert :ok =
             Email.deliver(
               "person@example.com",
               :appeal_rejected,
               "Confirmé",
               @contribution_path,
               "fr"
             )

    assert_email_sent(fn email ->
      assert email.subject == "Votre appel a été rejeté"
      assert email.text_body =~ "définitive"
    end)
  end

  test "delivers in English for locale \"en\"" do
    assert :ok =
             Email.deliver(
               "person@example.com",
               :accepted,
               "Good source",
               @contribution_path,
               "en"
             )

    assert_email_sent(fn email ->
      assert email.subject == "Your proposal has been accepted"
      assert email.text_body =~ "Good source"
    end)
  end
end
