defmodule Amanogawa.Atlas.EventLinkTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Atlas.EventLink

  @source_id Ecto.UUID.generate()
  @target_id Ecto.UUID.generate()

  describe "changeset/2 happy path" do
    test "valid with two distinct events and a known type" do
      changeset =
        EventLink.changeset(%EventLink{}, %{
          source_id: @source_id,
          target_id: @target_id,
          type: :part_of
        })

      assert changeset.valid?
    end
  end

  describe "changeset/2 error cases" do
    test "an auto-link is rejected" do
      changeset =
        EventLink.changeset(%EventLink{}, %{
          source_id: @source_id,
          target_id: @source_id,
          type: :follows
        })

      refute changeset.valid?
      assert "cannot link an event to itself" in errors_on(changeset).target_id
    end

    test "an unknown link type is rejected" do
      changeset =
        EventLink.changeset(%EventLink{}, %{
          source_id: @source_id,
          target_id: @target_id,
          type: :unknown
        })

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).type
    end
  end
end
