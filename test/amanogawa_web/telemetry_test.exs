defmodule AmanogawaWeb.TelemetryTest do
  use ExUnit.Case, async: true

  alias AmanogawaWeb.Telemetry

  test "metrics/0 returns telemetry metric definitions" do
    metrics = Telemetry.metrics()

    assert is_list(metrics)
    refute Enum.empty?(metrics)

    assert Enum.all?(metrics, fn metric ->
             is_struct(metric) and is_list(metric.name)
           end)
  end

  test "init/1 defines the telemetry poller supervision tree" do
    assert {:ok, {%{strategy: :one_for_one}, children}} = Telemetry.init(:ok)
    assert is_list(children)
  end
end
