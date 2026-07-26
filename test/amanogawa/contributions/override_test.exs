defmodule Amanogawa.Contributions.OverrideTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Contributions.Override

  @base_attrs %{source: "https://example.org/source", author_id: Ecto.UUID.generate()}

  describe "field_names/0" do
    test "the closed set of overridable business fields" do
      assert Override.field_names() == [:label_fr, :label_en, :begin_date, :end_date, :position]
    end
  end

  describe "propose_changeset/2, kind: :field" do
    test "happy path: a valid label_fr payload" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :label_fr,
          proposed_value: %{"value" => "Nouveau nom"}
        })

      assert %Ecto.Changeset{valid?: true} = Override.propose_changeset(%Override{}, attrs)
    end

    test "error: a label payload that is not %{\"value\" => string} is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :label_fr,
          proposed_value: %{"wrong_key" => "X"}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset).proposed_value == ["must be %{\"value\" => string}"]
    end

    test "error: a blank label value is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :label_fr,
          proposed_value: %{"value" => "   "}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset).proposed_value == ["value must not be blank"]
    end

    test "error: a label value longer than 500 characters is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :label_fr,
          proposed_value: %{"value" => String.duplicate("a", 501)}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
    end

    test "error: a malformed date payload is rejected with the underlying HistoricalDate error" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :begin_date,
          proposed_value: %{
            "year" => 100_000_000_000,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert [message] = errors_on(changeset).proposed_value
      assert message =~ "invalid date"
    end

    test "error: a date payload missing its required keys is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :begin_date,
          proposed_value: %{"foo" => "bar"}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset).proposed_value == ["must be a date payload"]
    end

    test "security: a forged calendar is REJECTED, never coerced and stored verbatim" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :begin_date,
          proposed_value: %{
            "year" => 1900,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "banana"
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?

      assert errors_on(changeset).proposed_value == [
               "calendar must be \"gregorian\" or \"julian\""
             ]
    end

    test "a nil calendar is still accepted (calendar unknown)" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :begin_date,
          proposed_value: %{
            "year" => 1900,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => nil
          }
        })

      assert %Ecto.Changeset{valid?: true} = Override.propose_changeset(%Override{}, attrs)
    end

    test "M3: a position payload is rounded to 6 decimals at proposal, symmetric with the sync's snapshots" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :position,
          proposed_value: %{"lon" => 2.352222177777, "lat" => 48.856614999999}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :proposed_value) == %{
               "lon" => 2.352222,
               "lat" => 48.856615
             }
    end

    test "happy path: a julian calendar date payload is accepted" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :begin_date,
          proposed_value: %{
            "year" => -100,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "julian"
          }
        })

      assert %Ecto.Changeset{valid?: true} = Override.propose_changeset(%Override{}, attrs)
    end

    test "error: a position payload missing lon/lat is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "Q123",
          field: :position,
          proposed_value: %{"lon" => 1.0}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?

      assert errors_on(changeset).proposed_value == [
               "must be %{\"lon\" => number, \"lat\" => number}"
             ]
    end

    test "error: an invalid event_qid format is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :field,
          event_qid: "not-a-qid",
          field: :label_fr,
          proposed_value: %{"value" => "X"}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "must be a valid event id" in errors_on(changeset).event_qid
    end
  end

  describe "propose_changeset/2, kind: :link" do
    test "happy path" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :link,
          event_qid: "Q123",
          target_qid: "Q456",
          link_type: :part_of
        })

      assert %Ecto.Changeset{valid?: true} = Override.propose_changeset(%Override{}, attrs)
    end

    test "error: a malformed target_qid is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :link,
          event_qid: "Q123",
          target_qid: "not-a-qid",
          link_type: :part_of
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "must be a valid event id" in errors_on(changeset).target_qid
    end

    test "error: an unknown link_type is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :link,
          event_qid: "Q123",
          target_qid: "Q456",
          link_type: :unknown_type
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
    end
  end

  describe "propose_changeset/2, kind: :new_event" do
    test "happy path" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => "Nouvel evenement",
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.0, "lat" => 48.0}
          }
        })

      assert %Ecto.Changeset{valid?: true} = Override.propose_changeset(%Override{}, attrs)
    end

    test "error: missing both label_fr and label_en" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.0, "lat" => 48.0}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "label_fr or label_en is required" in errors_on(changeset).proposed_value
    end

    test "error: a non-string label_fr is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => 123,
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.0, "lat" => 48.0}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "label must be a string" in errors_on(changeset).proposed_value
    end

    test "error: missing begin_date and position" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{"label_fr" => "X"}
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      errors = errors_on(changeset).proposed_value
      assert "begin_date is required" in errors
      assert "position is required" in errors
    end

    test "error: a description longer than 4000 characters is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => "X",
            "description_fr" => String.duplicate("a", 4001),
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.0, "lat" => 48.0}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "description is too long (max 4000)" in errors_on(changeset).proposed_value
    end

    test "error: a non-string description is rejected" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => "X",
            "description_en" => %{"nested" => "map"},
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.0, "lat" => 48.0}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      assert "description must be a string" in errors_on(changeset).proposed_value
    end

    test "a new_event position is rounded to 6 decimals at proposal too" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => "X",
            "begin_date" => %{
              "year" => 1900,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.352222177777, "lat" => 48.856614999999}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :proposed_value)["position"] == %{
               "lon" => 2.352222,
               "lat" => 48.856615
             }
    end

    test "error: a malformed nested begin_date or position is rejected with a prefixed message" do
      attrs =
        Map.merge(@base_attrs, %{
          kind: :new_event,
          proposed_value: %{
            "label_fr" => "X",
            "begin_date" => %{"year" => 100_000_000_000, "precision" => 9},
            "position" => %{"lon" => 200.0, "lat" => 0.0}
          }
        })

      changeset = Override.propose_changeset(%Override{}, attrs)
      refute changeset.valid?
      errors = errors_on(changeset).proposed_value
      assert Enum.any?(errors, &String.starts_with?(&1, "begin_date "))
      assert Enum.any?(errors, &String.starts_with?(&1, "position "))
    end
  end
end
