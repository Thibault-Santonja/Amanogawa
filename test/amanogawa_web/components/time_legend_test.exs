defmodule AmanogawaWeb.Components.TimeLegendTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AmanogawaWeb.Components.TimeLegend

  describe "time_legend/1" do
    test "renders the gradient bar sourced from the shared CSS tokens, never a hardcoded color" do
      assigns = %{from: -500, to: 500}

      html =
        rendered_to_string(~H"""
        <TimeLegend.time_legend from={@from} to={@to} />
        """)

      assert html =~ ~s(id="time-legend")
      assert html =~ "var(--time-start-color)"
      assert html =~ "var(--time-end-color)"
      refute html =~ "#"
      refute html =~ "rgb("
      refute html =~ "oklch("
    end

    test "a narrow window labels both bounds as exact years" do
      assigns = %{from: 1900, to: 1909}

      html =
        rendered_to_string(~H"""
        <TimeLegend.time_legend from={@from} to={@to} />
        """)

      assert html =~ "1900"
      assert html =~ "1909"
    end

    test "a BCE bound is labeled with the av. J.-C. convention" do
      assigns = %{from: -489, to: -480}

      html =
        rendered_to_string(~H"""
        <TimeLegend.time_legend from={@from} to={@to} />
        """)

      assert html =~ "490 av. J.-C."
      assert html =~ "481 av. J.-C."
    end

    test "a wide window labels both bounds at century granularity" do
      assigns = %{from: -500, to: 1500}

      html =
        rendered_to_string(~H"""
        <TimeLegend.time_legend from={@from} to={@to} />
        """)

      assert html =~ "s."
    end
  end
end
