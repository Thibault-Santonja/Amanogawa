defmodule Amanogawa.Alerting.Notifier do
  @moduledoc """
  Port for delivering an alert (issue #028): `Amanogawa.Alerting.
  ErrorReporter` depends on this behaviour only, never on `Amanogawa.Mailer`
  or Swoosh directly, so it stays testable with Mox
  (`Amanogawa.Alerting.NotifierMock`, `test/support/mocks.ex`) exactly like
  every other outbound port in this codebase.
  """

  @doc """
  Delivers an alert with the given `subject` and `body`.

  Returns `:ok` on success, `{:error, reason}` otherwise; the caller
  (`Amanogawa.Alerting.ErrorReporter`) is responsible for never letting a
  delivery failure crash or recurse (`.claude/rules/testing.md`'s own
  "l'erreur d'envoi ne redéclenche pas d'alerte").
  """
  @callback deliver(subject :: String.t(), body :: String.t()) :: :ok | {:error, term()}
end
