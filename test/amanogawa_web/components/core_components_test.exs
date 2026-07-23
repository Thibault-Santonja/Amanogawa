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
      assert html =~ "alert-info"
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
      assert html =~ "alert-error"
      assert html =~ ~s(id="my-flash")
    end

    test "renders nothing when there is no message" do
      assigns = %{flash: %{}}

      html =
        rendered_to_string(~H"""
        <CoreComponents.flash kind={:info} flash={@flash} />
        """)

      refute html =~ "alert-info"
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
      assert html =~ "btn-soft"
      assert html =~ "Send!"
    end

    test "renders the primary variant" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.button variant="primary">Go</CoreComponents.button>
        """)

      assert html =~ "btn-primary"
      refute html =~ "btn-soft"
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
      assert html =~ "input-error"
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

    test "renders a checkbox with normalized checked value" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input type="checkbox" id="opt-in" name="opt_in" label="Opt in" value={true} />
        """)

      assert html =~ ~s(type="checkbox")
      assert html =~ "checked"
      assert html =~ "Opt in"
    end

    test "renders a select with prompt and options" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input
          type="select"
          id="role"
          name="role"
          label="Role"
          prompt="Choose"
          options={[Admin: "admin", User: "user"]}
          value="user"
        />
        """)

      assert html =~ "<select"
      assert html =~ "Choose"
      assert html =~ ~s(value="admin")
      assert html =~ ~s(<option selected value="user">User</option>)
    end

    test "renders a textarea" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input type="textarea" id="bio" name="bio" label="Bio" value="hello" />
        """)

      assert html =~ "<textarea"
      assert html =~ "hello"
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

    test "appends [] to the name of a multiple select backed by a field" do
      form = to_form(%{}, as: :user)
      assigns = %{field: form[:roles]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.input field={@field} type="select" multiple options={[A: "a"]} />
        """)

      assert html =~ ~s(name="user[roles][]")
      assert html =~ "multiple"
    end
  end

  describe "header/1" do
    test "renders title, subtitle, and actions" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.header>
          The title
          <:subtitle>The subtitle</:subtitle>
          <:actions><button>Act</button></:actions>
        </CoreComponents.header>
        """)

      assert html =~ "The title"
      assert html =~ "The subtitle"
      assert html =~ "Act"
    end
  end

  describe "table/1" do
    test "renders rows with columns and actions" do
      assigns = %{rows: [%{id: 1, name: "Ada"}, %{id: 2, name: "Alan"}]}

      html =
        rendered_to_string(~H"""
        <CoreComponents.table id="users" rows={@rows} row_id={&"row-#{&1.id}"}>
          <:col :let={user} label="Name">{user.name}</:col>
          <:action :let={user}>
            <a href={"/users/#{user.id}"}>Show</a>
          </:action>
        </CoreComponents.table>
        """)

      assert html =~ "Ada"
      assert html =~ "Alan"
      assert html =~ ~s(id="row-1")
      assert html =~ "/users/2"
      assert html =~ "Name"
    end
  end

  describe "list/1" do
    test "renders titled items" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <CoreComponents.list>
          <:item title="Title">A post</:item>
          <:item title="Views">42</:item>
        </CoreComponents.list>
        """)

      assert html =~ "Title"
      assert html =~ "A post"
      assert html =~ "42"
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
