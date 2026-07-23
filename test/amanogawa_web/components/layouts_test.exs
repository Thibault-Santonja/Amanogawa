defmodule AmanogawaWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AmanogawaWeb.Layouts

  describe "app/1" do
    test "renders the three screen zones around the inner content" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>
          <div id="inner">Map placeholder</div>
        </Layouts.app>
        """)

      assert html =~ ~s(id="topbar")
      assert html =~ "Amanogawa"
      assert html =~ "Sources"
      assert html =~ "À propos"
      assert html =~ ~s(id="map-zone")
      assert html =~ "Map placeholder"
      assert html =~ ~s(id="timeline")
    end

    test "renders the flash group with the given flash" do
      assigns = %{flash: %{"info" => "Welcome"}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>
          <div>Content</div>
        </Layouts.app>
        """)

      assert html =~ "Welcome"
      assert html =~ ~s(id="flash-group")
    end
  end

  describe "flash_group/1" do
    test "renders info and error flashes plus connection error placeholders" do
      assigns = %{flash: %{"error" => "Broken"}}

      html =
        rendered_to_string(~H"""
        <Layouts.flash_group flash={@flash} />
        """)

      assert html =~ "Broken"
      assert html =~ ~s(id="client-error")
      assert html =~ ~s(id="server-error")
      assert html =~ ~s(id="flash-group")
    end
  end
end
