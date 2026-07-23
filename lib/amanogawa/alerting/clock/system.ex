defmodule Amanogawa.Alerting.Clock.System do
  @moduledoc "Default `Amanogawa.Alerting.Clock`: the real monotonic clock."

  @behaviour Amanogawa.Alerting.Clock

  @impl true
  def now_ms, do: System.monotonic_time(:millisecond)
end
