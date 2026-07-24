defmodule Amanogawa.Accounts.UserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Accounts.User

  alias Amanogawa.Accounts.User

  describe "normalize_email/1" do
    test "trims whitespace and downcases" do
      assert User.normalize_email("  User@Example.COM  ") == "user@example.com"
    end

    test "is idempotent" do
      normalized = User.normalize_email("User@Example.com")
      assert User.normalize_email(normalized) == normalized
    end
  end

  describe "changeset/2" do
    test "valid attrs produce a valid changeset with the normalized email" do
      changeset = User.changeset(%User{}, %{email: "  User@Example.COM  "})
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :email) == "user@example.com"
    end

    test "rejects an email without an @" do
      changeset = User.changeset(%User{}, %{email: "sans-arobase"})
      refute changeset.valid?
    end

    test "rejects an email containing whitespace" do
      changeset = User.changeset(%User{}, %{email: "user name@example.com"})
      refute changeset.valid?
    end

    test "rejects a missing email" do
      changeset = User.changeset(%User{}, %{})
      refute changeset.valid?
    end

    test "rejects an email longer than 160 characters" do
      too_long = String.duplicate("a", 155) <> "@a.com"
      changeset = User.changeset(%User{}, %{email: too_long})
      refute changeset.valid?
    end
  end

  describe "property: normalize_email/1 is idempotent for any email-shaped string" do
    property "normalizing twice equals normalizing once" do
      check all local <- StreamData.string(?a..?z, min_length: 1, max_length: 10),
                domain <- StreamData.string(?a..?z, min_length: 1, max_length: 10) do
        email = "#{local}@#{domain}.com"

        once = User.normalize_email(email)
        twice = User.normalize_email(once)

        assert once == twice
      end
    end
  end
end
