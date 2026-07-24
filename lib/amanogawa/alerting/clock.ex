defmodule Amanogawa.Alerting.Clock do
  @moduledoc """
  Time source for `Amanogawa.Alerting.ErrorReporter`'s sliding window and
  silence period (issue #028).

  A behaviour, like every other externally-observable port in this
  codebase (`Amanogawa.HealthCheck`, `Amanogawa.Ingestion.SparqlClient`),
  so tests can inject a controllable clock instead of `Process.sleep`ing
  through real minutes (`.claude/rules/testing.md`).
  """

  @callback now_ms() :: integer()
end
