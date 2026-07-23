defmodule Amanogawa.Atlas.PolityTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Atlas.Polity

  describe "changeset/2: happy path" do
    test "a valid attrs map produces a valid changeset" do
      changeset = Polity.changeset(%Polity{}, %{name: "Roman Empire", source: "cliopatria"})
      assert changeset.valid?
    end

    test "from_year and to_year are optional" do
      changeset =
        Polity.changeset(%Polity{}, %{
          name: "Roman Empire",
          source: "cliopatria",
          from_year: -27,
          to_year: 476
        })

      assert changeset.valid?
    end
  end

  describe "changeset/2: edge case" do
    test "from_year == to_year is accepted" do
      changeset =
        Polity.changeset(%Polity{}, %{name: "E", source: "s", from_year: 100, to_year: 100})

      assert changeset.valid?
    end

    test "only from_year present (to_year nil) is valid" do
      changeset = Polity.changeset(%Polity{}, %{name: "E", source: "s", from_year: 100})
      assert changeset.valid?
    end
  end

  describe "changeset/2: error case" do
    test "name is required" do
      changeset = Polity.changeset(%Polity{}, %{source: "cliopatria"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "source is required" do
      changeset = Polity.changeset(%Polity{}, %{name: "Roman Empire"})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "from_year > to_year is rejected" do
      changeset =
        Polity.changeset(%Polity{}, %{name: "E", source: "s", from_year: 500, to_year: 100})

      refute changeset.valid?
      assert "must be greater than or equal to from_year" in errors_on(changeset).to_year
    end
  end

  describe "database constraints" do
    test "(name, source) has a unique constraint" do
      %Polity{}
      |> Polity.changeset(%{name: "Roman Empire", source: "cliopatria"})
      |> Repo.insert!()

      assert {:error, changeset} =
               %Polity{}
               |> Polity.changeset(%{name: "Roman Empire", source: "cliopatria"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end

    test "the same name under a different source is a distinct row" do
      %Polity{}
      |> Polity.changeset(%{name: "Roman Empire", source: "cliopatria"})
      |> Repo.insert!()

      assert {:ok, _polity} =
               %Polity{}
               |> Polity.changeset(%{name: "Roman Empire", source: "historical_basemaps"})
               |> Repo.insert()
    end
  end
end
