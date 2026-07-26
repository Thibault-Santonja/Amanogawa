defmodule Amanogawa.Contributions.ConflictTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.ContributionsFixtures

  alias Amanogawa.Contributions.Conflict

  describe "reason_max_length/0" do
    test "the bounded length a conflict resolution's motive is held to" do
      assert Conflict.reason_max_length() == 1000
    end
  end

  describe "resolve_changeset/2" do
    test "happy path: moves an open conflict to resolved" do
      conflict = conflict_fixture()

      changeset =
        Conflict.resolve_changeset(conflict, %{
          resolution: :kept_override,
          resolved_by: Ecto.UUID.generate()
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :resolved
    end

    test "error case: a conflict that is not currently open cannot be resolved again" do
      conflict = conflict_fixture()

      resolved =
        conflict
        |> Conflict.resolve_changeset(%{resolution: :kept_override, resolved_by: nil})
        |> Ecto.Changeset.apply_action!(:update)

      changeset =
        Conflict.resolve_changeset(resolved, %{
          resolution: :adopted_wikidata,
          resolved_by: Ecto.UUID.generate()
        })

      refute changeset.valid?
      assert "can only resolve an open conflict" in errors_on(changeset).status
    end

    test "error case: a missing resolution is rejected" do
      conflict = conflict_fixture()

      changeset = Conflict.resolve_changeset(conflict, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).resolution
    end
  end
end
