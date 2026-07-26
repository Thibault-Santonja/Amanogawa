defmodule Amanogawa.Contributions.DecisionNotifier.Email do
  @moduledoc """
  Default `Amanogawa.Contributions.DecisionNotifier`: sends the decision
  as a plain-text email through `Amanogawa.Mailer` (issue #037), on the
  exact model of `Amanogawa.Accounts.MagicLinkNotifier.Mailer`.

  Reuses the sender address configured for `Amanogawa.Accounts`
  (`config :amanogawa, Amanogawa.Accounts, from: ...`, `ALERT_FROM_EMAIL`
  in production): every piece of Amanogawa's automated mail comes from
  the same address on a given host, so this avoids a second dedicated
  environment variable that would mean the exact same thing.

  Text only, no HTML, no remote resource (ADR 0008, zero tracking): the
  motive is included in full, the link is a plain URL a reader can copy,
  never a tracking pixel or a styled button.
  """

  @behaviour Amanogawa.Contributions.DecisionNotifier

  use Gettext, backend: AmanogawaWeb.Gettext

  import Swoosh.Email

  @impl true
  def deliver(email, outcome, message, contribution_path, locale) do
    from = Application.fetch_env!(:amanogawa, Amanogawa.Accounts) |> Keyword.fetch!(:from)
    url = AmanogawaWeb.Endpoint.url() <> contribution_path
    {subject, body} = render(outcome, message, url, locale)

    swoosh_email =
      new()
      |> to(email)
      |> from(from)
      |> subject(subject)
      |> text_body(body)

    case Amanogawa.Mailer.deliver(swoosh_email) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp render(outcome, message, url, locale) do
    Gettext.with_locale(AmanogawaWeb.Gettext, locale, fn ->
      {subject(outcome), body(outcome, message, url)}
    end)
  end

  defp subject(:accepted), do: dgettext("contributions", "Votre proposition a été acceptée")
  defp subject(:rejected), do: dgettext("contributions", "Votre proposition a été rejetée")

  defp subject(:appeal_accepted),
    do: dgettext("contributions", "Votre appel a été accepté")

  defp subject(:appeal_rejected),
    do: dgettext("contributions", "Votre appel a été rejeté")

  defp body(:accepted, message, url) do
    dgettext(
      "contributions",
      """
      Votre proposition a été acceptée par un relecteur.

      Motif : %{message}

      Vous pouvez consulter la contribution ici :

      %{url}
      """,
      message: message,
      url: url
    )
  end

  defp body(:rejected, message, url) do
    dgettext(
      "contributions",
      """
      Votre proposition a été rejetée par un relecteur.

      Motif : %{message}

      Vous pouvez consulter la contribution et, si besoin, y répondre une fois ici :

      %{url}
      """,
      message: message,
      url: url
    )
  end

  defp body(:appeal_accepted, message, url) do
    dgettext(
      "contributions",
      """
      Votre appel a été examiné et accepté : votre proposition est maintenant acceptée.

      Motif : %{message}

      Vous pouvez consulter la contribution ici :

      %{url}
      """,
      message: message,
      url: url
    )
  end

  defp body(:appeal_rejected, message, url) do
    dgettext(
      "contributions",
      """
      Votre appel a été examiné et rejeté. Cette décision est définitive.

      Motif : %{message}

      Vous pouvez consulter la contribution ici :

      %{url}
      """,
      message: message,
      url: url
    )
  end
end
