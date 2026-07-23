defmodule AmanogawaWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias AmanogawaWeb.CoreComponents
  alias Phoenix.LiveView.JS

  describe "flash/1" do
    test "renders an info flash message from the flash map" do
      assigns = %{flash: %{"info" => "Saved!"}}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info} flash={@flash} />
        """)

      assert html =~ "Saved!"
      assert html =~ ~s(data-kind="info")
      assert html =~ ~s(id="flash-info")
    end

    test "renders an error flash with title and inner block" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash id="my-flash" kind={:error} title="Oops">
          Something failed
        </CoreComponents.flash>
        """)

      assert html =~ "Oops"
      assert html =~ "Something failed"
      assert html =~ ~s(data-kind="error")
      assert html =~ ~s(id="my-flash")
    end

    test "renders nothing when there is no message" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info} flash={@flash} />
        """)

      refute html =~ "data-kind"
    end
  end

  describe "button/1" do
    test "renders a button element by default" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button>Send!</CoreComponents.button>
        """)

      assert html =~ "<button"
      assert html =~ "border-border"
      assert html =~ "Send!"
    end

    test "renders the primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary">Go</CoreComponents.button>
        """)

      assert html =~ "bg-accent"
      refute html =~ "border-border"
    end

    test "renders a link when given a navigation attribute" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button href="/somewhere">Home</CoreComponents.button>
        """)

      assert html =~ "<a"
      assert html =~ ~s(href="/somewhere")
      assert html =~ "Home"
    end
  end

  describe "input/1" do
    test "renders a text input with label" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input id="user-name" name="user[name]" label="Name" value="Ada" />
        """)

      assert html =~ ~s(type="text")
      assert html =~ ~s(name="user[name]")
      assert html =~ ~s(value="Ada")
      assert html =~ "Name"
    end

    test "renders errors passed explicitly" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input name="my-input" errors={["oh no!"]} value="" />
        """)

      assert html =~ "oh no!"
      assert html =~ "border-danger"
    end

    test "renders a hidden input" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input type="hidden" name="token" value="abc" />
        """)

      assert html =~ ~s(type="hidden")
      assert html =~ ~s(value="abc")
    end

    test "renders from a form field and shows its errors" do
      form =
        to_form(%{"email" => "not-an-email"},
          as: :user,
          errors: [email: {"is invalid", []}],
          action: :validate
        )

      assigns = %{field: form[:email]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input field={@field} type="email" label="Email" />
        """)

      assert html =~ ~s(id="user_email")
      assert html =~ ~s(name="user[email]")
      assert html =~ ~s(value="not-an-email")
      assert html =~ "is invalid"
    end
  end

  describe "icon/1" do
    test "renders a heroicon span with the given classes" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.icon name="hero-x-mark" class="size-5" />
        """)

      assert html =~ "hero-x-mark"
      assert html =~ "size-5"
    end
  end

  describe "JS commands" do
    test "show/2 builds a show command targeting the selector" do
      assert %JS{ops: [["show", %{to: "#modal"} = opts]]} = CoreComponents.show("#modal")
      assert opts[:time] == 300
    end

    test "hide/2 builds a hide command targeting the selector" do
      assert %JS{ops: [["hide", %{to: "#modal"} = opts]]} = CoreComponents.hide("#modal")
      assert opts[:time] == 200
    end
  end

  describe "translate_error/1" do
    test "translates a simple message" do
      assert CoreComponents.translate_error({"is invalid", []}) == "is invalid"
    end

    test "translates a message with count interpolation" do
      msg = "should be at least %{count} character(s)"

      assert CoreComponents.translate_error({msg, count: 3}) ==
               "should be at least 3 character(s)"
    end
  end

  describe "translate_errors/2" do
    test "translates all errors for the given field" do
      errors = [name: {"can't be blank", []}, name: {"is too short", []}, age: {"nope", []}]

      assert CoreComponents.translate_errors(errors, :name) ==
               ["can't be blank", "is too short"]
    end
  end
end
