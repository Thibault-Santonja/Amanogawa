defmodule Amanogawa.Alerting.Notifier.Mailer do
  @moduledoc """
  Default `Amanogawa.Alerting.Notifier`: sends the alert as a plain-text
  email through `Amanogawa.Mailer` (issue #028).

  Both the sender and the recipient addresses are read from config at
  call time (`config :amanogawa, Amanogawa.Alerting`, set from
  `ALERT_FROM_EMAIL`/`ALERT_RECIPIENT_EMAIL` by `config/runtime.exs`), not
  compiled in: this module holds no environment-specific value of its
  own, matching the rest of the deployment layer (Dockerfile,
  config/deploy.yml).
  """

  @behaviour Amanogawa.Alerting.Notifier

  import Swoosh.Email

  @impl true
  def deliver(subject, body) do
    config = Application.fetch_env!(:amanogawa, Amanogawa.Alerting)

    email =
      new()
      |> to(Keyword.fetch!(config, :recipient))
      |> from(Keyword.fetch!(config, :from))
      |> subject(subject)
      |> text_body(body)

    case Amanogawa.Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
