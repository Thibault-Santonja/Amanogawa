defmodule Amanogawa.Accounts.MagicLinkNotifier.Mailer do
  @moduledoc """
  Default `Amanogawa.Accounts.MagicLinkNotifier`: sends the magic link as
  a plain-text email through `Amanogawa.Mailer` (issue #031), on the
  exact model of `Amanogawa.Alerting.Notifier.Mailer`.

  The sender address is read from config at call time
  (`config :amanogawa, Amanogawa.Accounts`, set from `ALERT_FROM_EMAIL`
  by `config/runtime.exs` in production, with a documented placeholder
  fallback in dev/test): reused rather than inventing a second dedicated
  environment variable, since both addresses mean the same thing, "where
  Amanogawa's automated mail comes from" on this host.

  The locale is a parameter of `deliver/3`, applied with `Gettext.
  with_locale/3` around the whole render: delivery can run
  asynchronously (a future Oban-backed send), so it must never depend on
  the calling process's own Gettext locale.

  Text only, no HTML, no remote resource of any kind (ADR 0008, zero
  tracking): exactly like the alerting mailer, sober and readable
  everywhere, and with nothing a scanner or a mail client could
  preload.
  """

  @behaviour Amanogawa.Accounts.MagicLinkNotifier

  use Gettext, backend: AmanogawaWeb.Gettext

  import Swoosh.Email

  alias Amanogawa.Accounts.MagicLink

  @impl true
  def deliver(email, magic_link_url, locale) do
    from = Application.fetch_env!(:amanogawa, Amanogawa.Accounts) |> Keyword.fetch!(:from)
    {subject, body} = render(magic_link_url, locale)

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

  defp render(magic_link_url, locale) do
    Gettext.with_locale(AmanogawaWeb.Gettext, locale, fn ->
      {subject(), body(magic_link_url)}
    end)
  end

  defp subject, do: dgettext("accounts", "Votre lien de connexion Amanogawa")

  defp body(magic_link_url) do
    dgettext(
      "accounts",
      """
      Voici votre lien de connexion :

      %{url}

      Ce lien est valable %{minutes} minutes et ne peut être utilisé qu'une seule fois.

      Si vous n'êtes pas à l'origine de cette demande, vous pouvez ignorer cet email.
      """,
      url: magic_link_url,
      minutes: Integer.to_string(MagicLink.validity_minutes())
    )
  end
end
