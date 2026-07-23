defmodule AmanogawaWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AmanogawaWeb.Layouts

  describe "app/1" do
    test "renders the header, the inner content, and the flash group" do
      assigns = %{flash: %{"info" => "Welcome"}}

      html =
        rendered_to_string(~H"""
        <Layouts.app flash={@flash}>
          <h1>Page content</h1>
        </Layouts.app>
        """)

      assert html =~ "Page content"
      assert html =~ "Welcome"
      assert html =~ "navbar"
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

  describe "theme_toggle/1" do
    test "renders the three theme buttons" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <Layouts.theme_toggle />
        """)

      assert html =~ ~s(data-phx-theme="system")
      assert html =~ ~s(data-phx-theme="light")
      assert html =~ ~s(data-phx-theme="dark")
    end
  end
end
