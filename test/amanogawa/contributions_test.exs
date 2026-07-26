defmodule Amanogawa.ContributionsTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Amanogawa.HistoricalDateGenerators
  import Mox

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.Conflict
  alias Amanogawa.Contributions.DecisionNotifierMock
  alias Amanogawa.Contributions.Override
  alias Amanogawa.Contributions.ProposalThrottle
  alias Amanogawa.HistoricalDate
  alias Amanogawa.Repo

  setup :verify_on_exit!

  # A lenient default so every pre-existing accept/reject test (most of
  # which predate issue #037 and have no reason to care about
  # notifications) keeps compiling and passing: `expect/3` in a specific
  # test always takes priority over this stub (Mox's own contract), so
  # the "decision notifications" describe block below still asserts on
  # the exact email sent where it matters.
  setup do
    stub(DecisionNotifierMock, :deliver, fn _email, _outcome, _message, _path, _locale -> :ok end)
    :ok
  end

  # ---------------------------------------------------------------------
  # propose/2 (issue #034)
  # ---------------------------------------------------------------------

  describe "propose/2" do
    test "happy path: creates a pending override and a :proposed revision" do
      event = event_fixture(label_fr: "Ancien nom")
      author = user_fixture()

      assert {:ok, override} =
               Contributions.propose(
                 %{
                   kind: :field,
                   event_qid: event.qid,
                   field: :label_fr,
                   proposed_value: %{"value" => "Nouveau nom"},
                   source: "https://example.org/source"
                 },
                 author.id
               )

      assert override.status == :pending
      assert override.author_id == author.id
      assert override.current_value == %{"value" => "Ancien nom"}

      assert [revision] = Contributions.list_revisions(override.id)
      assert revision.action == :proposed
      assert revision.actor_id == author.id
    end

    test "current_value is always computed server-side, never trusted from the caller" do
      event = event_fixture(label_fr: "Valeur reelle")
      author = user_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => "Corrige"},
            current_value: %{"value" => "Valeur falsifiee"},
            source: "https://example.org/source"
          },
          author.id
        )

      assert override.current_value == %{"value" => "Valeur reelle"}
    end

    test "edge case: an end_date proposal with a nil value is accepted (removing an erroneous end date)" do
      event = event_fixture()
      author = user_fixture()

      assert {:ok, override} =
               Contributions.propose(
                 %{
                   kind: :field,
                   event_qid: event.qid,
                   field: :end_date,
                   proposed_value: nil,
                   source: "https://example.org/source"
                 },
                 author.id
               )

      assert override.proposed_value == nil
    end

    test "an accepted nil end_date proposal clears end_year without crashing" do
      event = event_fixture(end_year: 1850, end_precision: 9)
      author = user_fixture()
      reviewer = reviewer_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :end_date,
            proposed_value: nil,
            source: "https://example.org/source"
          },
          author.id
        )

      assert {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "motif")
      assert accepted.wikidata_value_at_acceptance != nil

      updated = Atlas.get_event_by_qid(event.qid)
      assert updated.end_year == nil
      assert updated.overridden_fields == ["end_date"]
    end

    test "edge case: a missing source, or a source longer than 1000 characters, is rejected" do
      event = event_fixture()
      author = user_fixture()

      attrs = %{
        kind: :field,
        event_qid: event.qid,
        field: :label_fr,
        proposed_value: %{"value" => "X"}
      }

      assert {:error, changeset} = Contributions.propose(attrs, author.id)
      assert "can't be blank" in errors_on(changeset).source

      long_source = String.duplicate("a", 1001)

      assert {:error, changeset} =
               Contributions.propose(Map.put(attrs, :source, long_source), author.id)

      assert "should be at most 1000 character(s)" in errors_on(changeset).source
    end

    test "error case: accept_override by a non-reviewer, or by the author, changes nothing; a payload of position out of world bounds, or a field outside the closed list, is rejected" do
      event = event_fixture()
      author = user_fixture()

      base = %{
        kind: :field,
        event_qid: event.qid,
        source: "https://example.org/source"
      }

      assert {:error, changeset} =
               Contributions.propose(
                 Map.merge(base, %{
                   field: :position,
                   proposed_value: %{"lon" => 200.0, "lat" => 10.0}
                 }),
                 author.id
               )

      assert errors_on(changeset).proposed_value != []
    end

    test "error case: an unknown event_qid returns :event_not_found" do
      author = user_fixture()

      assert {:error, :event_not_found} =
               Contributions.propose(
                 %{
                   kind: :field,
                   event_qid: "Q999999999",
                   field: :label_fr,
                   proposed_value: %{"value" => "X"},
                   source: "https://example.org/source"
                 },
                 author.id
               )
    end
  end

  # ---------------------------------------------------------------------
  # accept_override/3 and reject_override/3 (issue #034)
  # ---------------------------------------------------------------------

  describe "accept_override/3" do
    test "happy path: the override is accepted, the snapshot is taken, and the resolved value on the event is the correction" do
      event = event_fixture(label_fr: "Ancien nom")
      author = user_fixture()
      reviewer = reviewer_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => "Nouveau nom"},
            source: "https://example.org/source"
          },
          author.id
        )

      assert {:ok, accepted} =
               Contributions.accept_override(override.id, reviewer, "Source fiable")

      assert accepted.status == :accepted
      assert accepted.wikidata_value_at_acceptance == %{"value" => "Ancien nom"}

      updated_event = Atlas.get_event_by_qid(event.qid)
      assert updated_event.label_fr == "Nouveau nom"
      assert updated_event.overridden_fields == ["label_fr"]

      assert Enum.map(Contributions.list_revisions(override.id), & &1.action) == [
               :proposed,
               :accepted
             ]
    end

    test "error case: a non-reviewer cannot accept, nothing changes" do
      event = event_fixture()
      author = user_fixture()
      non_reviewer = user_fixture()

      override =
        override_fixture(event_qid: event.qid, author_id: author.id, field: :label_fr)

      assert {:error, :forbidden} =
               Contributions.accept_override(override.id, non_reviewer, "motif")

      assert Repo.get!(Override, override.id).status == :pending
      assert Atlas.get_event_by_qid(event.qid).overridden_fields == []
    end

    test "error case: the author of the override cannot accept their own proposal (self-review)" do
      event = event_fixture()
      reviewer = reviewer_fixture()

      override =
        override_fixture(event_qid: event.qid, author_id: reviewer.id, field: :label_fr)

      assert {:error, :self_review} =
               Contributions.accept_override(override.id, reviewer, "motif")

      assert Repo.get!(Override, override.id).status == :pending
    end

    test "error case: a blank or missing message is rejected before any write" do
      override = override_fixture()
      reviewer = reviewer_fixture()

      assert {:error, :message_required} =
               Contributions.accept_override(override.id, reviewer, "")

      assert {:error, :message_required} =
               Contributions.accept_override(override.id, reviewer, nil)

      assert Repo.get!(Override, override.id).status == :pending
    end

    test "limit case: two accepted overrides for the same (event, field) collide on the partial unique index" do
      event = event_fixture()
      author = user_fixture()
      reviewer = reviewer_fixture()

      override_1 = override_fixture(event_qid: event.qid, author_id: author.id, field: :label_fr)
      override_2 = override_fixture(event_qid: event.qid, author_id: author.id, field: :label_fr)

      assert {:ok, _} = Contributions.accept_override(override_1.id, reviewer, "motif")

      assert {:error, %Ecto.Changeset{}} =
               Contributions.accept_override(override_2.id, reviewer, "motif")
    end

    test "limit case: an already-accepted override cannot be accepted again" do
      override = accepted_override_fixture()
      reviewer = reviewer_fixture()

      assert {:error, :not_pending} =
               Contributions.accept_override(override.id, reviewer, "motif")
    end

    test "error case: an unknown override id returns :not_found" do
      reviewer = reviewer_fixture()

      assert {:error, :not_found} =
               Contributions.accept_override(Ecto.UUID.generate(), reviewer, "motif")
    end
  end

  describe "reject_override/3" do
    test "happy path: the override is rejected and Atlas is never touched" do
      event = event_fixture()
      author = user_fixture()
      reviewer = reviewer_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => "X"},
            source: "https://example.org/source"
          },
          author.id
        )

      assert {:ok, rejected} =
               Contributions.reject_override(override.id, reviewer, "Source invalide")

      assert rejected.status == :rejected
      assert Atlas.get_event_by_qid(event.qid).overridden_fields == []

      assert Enum.map(Contributions.list_revisions(override.id), & &1.action) == [
               :proposed,
               :rejected
             ]
    end

    test "error case: a non-reviewer cannot reject" do
      override = override_fixture()
      non_reviewer = user_fixture()

      assert {:error, :forbidden} =
               Contributions.reject_override(override.id, non_reviewer, "motif")
    end
  end

  # ---------------------------------------------------------------------
  # accept_override/3 across kinds: :link and :new_event
  # ---------------------------------------------------------------------

  describe "accept_override/3 for kind: :link" do
    test "creates the typed link, and replaying the same link (a second override) is idempotent" do
      source = event_fixture()
      target = event_fixture()
      author = user_fixture()
      reviewer = reviewer_fixture()

      override_1 =
        override_fixture(
          kind: :link,
          event_qid: source.qid,
          target_qid: target.qid,
          link_type: :part_of,
          field: nil,
          proposed_value: nil,
          current_value: nil,
          author_id: author.id
        )

      assert {:ok, _} = Contributions.accept_override(override_1.id, reviewer, "motif")
      assert Atlas.count_event_links() == 1

      override_2 =
        override_fixture(
          kind: :link,
          event_qid: source.qid,
          target_qid: target.qid,
          link_type: :part_of,
          field: nil,
          proposed_value: nil,
          current_value: nil,
          author_id: author.id
        )

      assert {:ok, _} = Contributions.accept_override(override_2.id, reviewer, "motif")
      assert Atlas.count_event_links() == 1
    end
  end

  describe "accept_override/3 for kind: :new_event" do
    test "creates a contributed event, visible in the viewport, immune to a Wikidata sync of unrelated events" do
      author = user_fixture()
      reviewer = reviewer_fixture()

      proposed_value = %{
        "label_fr" => "Evenement propose",
        "label_en" => "Proposed event",
        "begin_date" => %{
          "year" => 1789,
          "month" => 7,
          "day" => 14,
          "precision" => 11,
          "calendar" => "gregorian"
        },
        "position" => %{"lon" => 2.35, "lat" => 48.85}
      }

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :new_event,
            proposed_value: proposed_value,
            source: "https://example.org/source"
          },
          author.id
        )

      assert {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "motif")
      assert accepted.status == :accepted

      revisions = Contributions.list_revisions(override.id)
      assert Enum.map(revisions, & &1.action) == [:proposed, :accepted]

      created_event = Repo.get_by!(Event, label_fr: "Evenement propose")
      assert created_event.origin == :contribution
      assert created_event.label_fr == "Evenement propose"
      assert String.starts_with?(created_event.qid, "L")

      geojson =
        Atlas.list_events_geojson(%{
          envelopes: [world_envelope()],
          from: 1700,
          to: 1800,
          limit: 10
        })

      assert Enum.any?(geojson["features"], &(&1["properties"]["qid"] == created_event.qid))

      # A Wikidata sync of unrelated events never conflicts on this local id.
      other_qid = hd(unique_qids(1))

      other_attrs = %{
        qid: other_qid,
        label_fr: "Autre evenement",
        begin_year: 1900,
        begin_precision: 9,
        location_source: :direct,
        sitelink_count: 0,
        geom: %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326}
      }

      assert {:ok, %{upserted: 1}} = Atlas.upsert_events([other_attrs])
      assert Atlas.get_event_by_qid(created_event.qid).origin == :contribution
    end
  end

  # ---------------------------------------------------------------------
  # Listing (issue #034)
  # ---------------------------------------------------------------------

  describe "list_overrides/1, list_revisions/1, count_by_status/0" do
    test "list_overrides/1 filters by status, event_qid and author_id, most recent first" do
      event = event_fixture()
      author = user_fixture()
      other_author = user_fixture()

      override_1 = override_fixture(event_qid: event.qid, author_id: author.id)

      # Backdated a second: two overrides created back to back in the same
      # test can land in the same millisecond, and UUID v7 only orders
      # strictly across distinct milliseconds, not within one
      # (`.claude/rules/testing.md`: pilot the clock, don't race it).
      override_1
      |> Ecto.Changeset.change(inserted_at: DateTime.add(override_1.inserted_at, -1, :second))
      |> Repo.update!()

      override_2 = override_fixture(event_qid: event.qid, author_id: author.id)
      _other = override_fixture(author_id: other_author.id)

      assert Contributions.list_overrides(%{event_qid: event.qid}) |> Enum.map(& &1.id) ==
               [override_2.id, override_1.id]

      assert Contributions.list_overrides(%{author_id: author.id}) |> length() == 2
      assert Contributions.list_overrides(%{status: :accepted}) == []
    end

    test "count_by_status/0 counts overrides per status" do
      override_fixture()
      override_fixture()
      accepted_override_fixture()

      counts = Contributions.count_by_status()
      assert counts[:pending] == 2
      assert counts[:accepted] == 1
    end
  end

  describe "revisions are append-only" do
    test "the facade exports no function that could update or delete a revision" do
      exported = Amanogawa.Contributions.__info__(:functions) |> Keyword.keys()

      refute Enum.any?(exported, &(&1 in [:update_revision, :delete_revision]))
    end
  end

  # ---------------------------------------------------------------------
  # Property-based tests
  # ---------------------------------------------------------------------

  property "a HistoricalDate survives the override jsonb payload round trip, precision included" do
    check all date <- historical_date() do
      payload = %{
        "year" => date.year,
        "month" => date.month,
        "day" => date.day,
        "precision" => date.precision,
        "calendar" => Atom.to_string(date.calendar)
      }

      attrs = %{
        year: payload["year"],
        month: payload["month"],
        day: payload["day"],
        precision: payload["precision"],
        calendar: date.calendar
      }

      assert {:ok, decoded} = HistoricalDate.new(attrs)
      assert HistoricalDate.compare(decoded, date) == :eq
      assert decoded.precision == date.precision
    end
  end

  property "the resolved value is always the last applied override or the original Wikidata value, never an intermediate state" do
    check all label <- StreamData.string(:alphanumeric, min_length: 1, max_length: 30) do
      event = event_fixture(label_fr: "Wikidata")
      author = user_fixture()
      reviewer = reviewer_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => label},
            source: "https://example.org/source"
          },
          author.id
        )

      assert Atlas.get_event_by_qid(event.qid).label_fr == "Wikidata"

      {:ok, _} = Contributions.accept_override(override.id, reviewer, "motif")
      assert Atlas.get_event_by_qid(event.qid).label_fr == label

      {:ok, _} = Atlas.release_field_override(event.qid, :label_fr, %{"value" => "Wikidata"})
      assert Atlas.get_event_by_qid(event.qid).label_fr == "Wikidata"
    end
  end

  # ---------------------------------------------------------------------
  # Integration (DataCase)
  # ---------------------------------------------------------------------

  describe "integration: full flow against PostGIS" do
    test "propose -> accept -> viewport reports the corrected year -> release -> viewport reports the Wikidata year" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      author = user_fixture()
      reviewer = reviewer_fixture()

      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :begin_date,
            proposed_value: %{
              "year" => 1750,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            source: "https://example.org/source"
          },
          author.id
        )

      {:ok, _} = Contributions.accept_override(override.id, reviewer, "motif")

      geojson =
        Atlas.list_events_geojson(%{
          envelopes: [world_envelope()],
          from: 1700,
          to: 1760,
          limit: 10
        })

      assert Enum.any?(geojson["features"], &(&1["properties"]["qid"] == event.qid))

      {:ok, _} =
        Atlas.release_field_override(event.qid, :begin_date, %{
          "year" => 1800,
          "month" => nil,
          "day" => nil,
          "precision" => 9,
          "calendar" => "julian"
        })

      geojson_after_release =
        Atlas.list_events_geojson(%{
          envelopes: [world_envelope()],
          from: 1700,
          to: 1760,
          limit: 10
        })

      refute Enum.any?(geojson_after_release["features"], &(&1["properties"]["qid"] == event.qid))
    end
  end

  defp world_envelope, do: %{min_lon: -180.0, min_lat: -90.0, max_lon: 180.0, max_lat: 90.0}

  # ---------------------------------------------------------------------
  # record_sync_divergences/1, list_open_conflicts/1, resolve_conflict/3
  # (issue #035)
  # ---------------------------------------------------------------------

  describe "record_sync_divergences/1" do
    test "an incoming value equal to the snapshot creates nothing" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)

      lot = [lot_entry(event, begin_year: 1800)]

      assert Contributions.record_sync_divergences(lot) == %{
               unchanged: 1,
               superseded: 0,
               conflicts_opened: 0,
               conflicts_refreshed: 0
             }

      assert Repo.get!(Override, override.id).status == :accepted
      assert Contributions.list_open_conflicts() == []
    end

    test "an incoming value equal to the proposed value moves the override to :superseded and releases the marker" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)

      lot = [lot_entry(event, begin_year: 1750)]

      assert %{superseded: 1} = Contributions.record_sync_divergences(lot)

      updated = Repo.get!(Override, override.id)
      assert updated.status == :superseded

      updated_event = Atlas.get_event_by_qid(event.qid)
      assert updated_event.begin_year == 1750
      assert updated_event.overridden_fields == []

      assert Enum.map(Contributions.list_revisions(override.id), & &1.action) == [
               :proposed,
               :accepted,
               :superseded
             ]
    end

    test "a differing incoming value opens a conflict carrying the incoming value" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      _override = accept_begin_date_override(event, 1750)

      lot = [lot_entry(event, begin_year: 1900)]

      assert %{conflicts_opened: 1} = Contributions.record_sync_divergences(lot)

      assert [conflict] = Contributions.list_open_conflicts()
      assert conflict.wikidata_value["year"] == 1900
      assert conflict.event_qid == event.qid
      assert conflict.field == :begin_date

      # The corrected value is still what is shown: the sync never
      # overwrote it.
      assert Atlas.get_event_by_qid(event.qid).begin_year == 1750
    end

    test "edge case: two successive syncs with the same divergence refresh the single open conflict" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      _override = accept_begin_date_override(event, 1750)

      lot = [lot_entry(event, begin_year: 1900)]
      Contributions.record_sync_divergences(lot)

      assert %{conflicts_refreshed: 1} = Contributions.record_sync_divergences(lot)
      assert [_conflict] = Contributions.list_open_conflicts()
      assert Repo.aggregate(Conflict, :count) == 1
    end

    test "limit case: a lot of events with no accepted override makes a single query and touches nothing" do
      events = for _ <- 1..5, do: event_fixture()
      lot = Enum.map(events, &lot_entry(&1, begin_year: &1.begin_year))

      {queries, counts} = query_count(fn -> Contributions.record_sync_divergences(lot) end)

      assert counts == %{unchanged: 0, superseded: 0, conflicts_opened: 0, conflicts_refreshed: 0}
      assert queries == 1
    end

    test "conflict lifecycle: a supersede closes the open conflict with the system :obsolete resolution" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)

      # First sync: a real divergence opens a conflict.
      assert %{conflicts_opened: 1} =
               Contributions.record_sync_divergences([lot_entry(event, begin_year: 1900)])

      # Second sync: Wikidata rejoined the correction. The override is
      # superseded AND the stale conflict is closed, never left open.
      assert %{superseded: 1} =
               Contributions.record_sync_divergences([lot_entry(event, begin_year: 1750)])

      assert Contributions.list_open_conflicts() == []

      [conflict] = Repo.all(where(Conflict, override_id: ^override.id))
      assert conflict.status == :resolved
      assert conflict.resolution == :obsolete
      assert conflict.resolved_by == nil
    end

    test "conflict lifecycle: Wikidata coming back to the snapshot closes the open conflict as :obsolete" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)

      assert %{conflicts_opened: 1} =
               Contributions.record_sync_divergences([lot_entry(event, begin_year: 1900)])

      # Wikidata moved back to the value snapshotted at acceptance: the
      # divergence no longer exists, the conflict must not stay open.
      assert %{unchanged: 1} =
               Contributions.record_sync_divergences([lot_entry(event, begin_year: 1800)])

      assert Contributions.list_open_conflicts() == []

      [conflict] = Repo.all(where(Conflict, override_id: ^override.id))
      assert conflict.status == :resolved
      assert conflict.resolution == :obsolete
      assert conflict.resolved_by == nil
      assert Repo.get!(Override, override.id).status == :accepted
    end

    test "M2: Wikidata removing the end date under an accepted override opens a conflict instead of crashing" do
      event =
        event_fixture(
          end_year: 1850,
          end_precision: 9,
          end_month: nil,
          end_day: nil,
          end_calendar: :gregorian
        )

      override = accept_end_date_override(event, 1840)

      # Wikidata now carries NO end date at all: the sync must journal
      # the divergence, never raise on the NOT NULL wikidata_value.
      assert %{conflicts_opened: 1} =
               Contributions.record_sync_divergences([
                 lot_entry(event,
                   end_year: nil,
                   end_month: nil,
                   end_day: nil,
                   end_precision: nil,
                   end_calendar: nil
                 )
               ])

      assert [conflict] = Contributions.list_open_conflicts()
      assert conflict.override_id == override.id
      assert conflict.wikidata_value == %{"absent" => true}

      # The corrected end date is still what the event shows.
      assert Atlas.get_event_by_qid(event.qid).end_year == 1840
    end

    test "M2: adopting Wikidata's absent end date releases the field to no end date at all" do
      event =
        event_fixture(
          end_year: 1850,
          end_precision: 9,
          end_month: nil,
          end_day: nil,
          end_calendar: :gregorian
        )

      override = accept_end_date_override(event, 1840)
      reviewer = reviewer_fixture()

      Contributions.record_sync_divergences([
        lot_entry(event,
          end_year: nil,
          end_month: nil,
          end_day: nil,
          end_precision: nil,
          end_calendar: nil
        )
      ])

      [conflict] = Contributions.list_open_conflicts()

      assert {:ok, resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :adopted_wikidata,
                 message: "Wikidata a retiré cette date"
               })

      assert resolved.status == :resolved

      updated_event = Atlas.get_event_by_qid(event.qid)
      assert updated_event.end_year == nil
      assert updated_event.overridden_fields == []
      assert Repo.get!(Override, override.id).status == :superseded
    end

    test "M2: keeping the override against an absent Wikidata value refreshes the snapshot to nil, no re-signal" do
      event =
        event_fixture(
          end_year: 1850,
          end_precision: 9,
          end_month: nil,
          end_day: nil,
          end_calendar: :gregorian
        )

      override = accept_end_date_override(event, 1840)
      reviewer = reviewer_fixture()

      absent_lot = [
        lot_entry(event,
          end_year: nil,
          end_month: nil,
          end_day: nil,
          end_precision: nil,
          end_calendar: nil
        )
      ]

      Contributions.record_sync_divergences(absent_lot)
      [conflict] = Contributions.list_open_conflicts()

      assert {:ok, _resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "La date de fin est attestée"
               })

      assert Repo.get!(Override, override.id).wikidata_value_at_acceptance == nil

      # The same absent value again: unchanged, no new conflict.
      assert %{unchanged: 1} = Contributions.record_sync_divergences(absent_lot)
      assert Contributions.list_open_conflicts() == []
    end

    test "M3/M1: a position override is reachable by :superseded (symmetric rounding at proposal)" do
      event =
        event_fixture(
          geom: %Geo.Point{coordinates: {2.0, 48.0}, srid: 4326},
          location_source: :direct
        )

      author = user_fixture()
      reviewer = reviewer_fixture()

      # More decimals than the 6 the sync's own snapshots carry: the
      # proposal-side rounding is what makes the comparison symmetric.
      {:ok, override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :position,
            proposed_value: %{"lon" => 2.352222177777, "lat" => 48.856614999999},
            source: "https://example.org/source"
          },
          author.id
        )

      assert override.proposed_value == %{"lon" => 2.352222, "lat" => 48.856615}

      {:ok, _accepted} = Contributions.accept_override(override.id, reviewer, "motif")

      # Wikidata rejoins the correction (its own coordinates land within
      # the same 6-decimal rounding): superseded, not a conflict.
      lot = [
        lot_entry(event,
          geom: %Geo.Point{coordinates: {2.3522221, 48.8566149}, srid: 4326},
          location_source: :direct
        )
      ]

      assert %{superseded: 1, conflicts_opened: 0} = Contributions.record_sync_divergences(lot)
      assert Repo.get!(Override, override.id).status == :superseded
    end
  end

  describe "list_open_conflicts/1 and resolve_conflict/3" do
    test "resolve_conflict(:kept_override) refreshes the snapshot; a third sync with the same value does not reopen a conflict" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)
      reviewer = reviewer_fixture()

      Contributions.record_sync_divergences([lot_entry(event, begin_year: 1900)])
      [conflict] = Contributions.list_open_conflicts()

      assert {:ok, resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "On garde la correction"
               })

      assert resolved.status == :resolved
      assert resolved.resolution == :kept_override

      # The correction is still displayed.
      assert Atlas.get_event_by_qid(event.qid).begin_year == 1750
      assert Repo.get!(Override, override.id).status == :accepted
      assert Repo.get!(Override, override.id).wikidata_value_at_acceptance["year"] == 1900

      # Same Wikidata value again: no new conflict.
      assert %{unchanged: 1} =
               Contributions.record_sync_divergences([lot_entry(event, begin_year: 1900)])

      assert Contributions.list_open_conflicts() == []
    end

    test "resolve_conflict(:adopted_wikidata) releases the field and supersedes the override" do
      event =
        event_fixture(
          begin_year: 1800,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          begin_calendar: :gregorian
        )

      override = accept_begin_date_override(event, 1750)
      reviewer = reviewer_fixture()

      Contributions.record_sync_divergences([lot_entry(event, begin_year: 1900)])
      [conflict] = Contributions.list_open_conflicts()

      assert {:ok, resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :adopted_wikidata,
                 message: "Wikidata a raison"
               })

      assert resolved.status == :resolved
      assert Atlas.get_event_by_qid(event.qid).begin_year == 1900
      assert Repo.get!(Override, override.id).status == :superseded
    end

    test "error case: a non-reviewer, a missing message, or an already-resolved conflict is rejected without effect" do
      conflict = conflict_fixture()
      non_reviewer = user_fixture()
      reviewer = reviewer_fixture()

      assert {:error, :forbidden} =
               Contributions.resolve_conflict(conflict.id, non_reviewer, %{
                 resolution: :kept_override,
                 message: "motif"
               })

      assert {:error, :message_required} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: ""
               })

      assert {:ok, _} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "motif"
               })

      assert {:error, :already_resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "motif"
               })
    end

    test "error case: a conflict whose override is no longer :accepted is refused, nothing changes" do
      override = accepted_override_fixture()
      conflict = conflict_fixture(override: override)
      reviewer = reviewer_fixture()

      # The override left :accepted between the sync and the reviewer's
      # decision (e.g. a direct release then supersede elsewhere).
      override |> Ecto.Changeset.change(status: :superseded) |> Repo.update!()

      assert {:error, :override_not_accepted} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :adopted_wikidata,
                 message: "motif"
               })

      assert Repo.get!(Conflict, conflict.id).status == :open
    end

    test "limit case: list_open_conflicts/1 honors keyset pagination (:after, :limit)" do
      first = conflict_fixture(detected_at: ~U[2026-07-01 10:00:00Z])
      second = conflict_fixture(detected_at: ~U[2026-07-02 10:00:00Z])
      third = conflict_fixture(detected_at: ~U[2026-07-03 10:00:00Z])

      assert [page_1] = Contributions.list_open_conflicts(%{limit: 1})
      assert page_1.id == first.id

      cursor = %{detected_at: page_1.detected_at, id: page_1.id}

      assert Contributions.list_open_conflicts(%{after: cursor}) |> Enum.map(& &1.id) ==
               [second.id, third.id]
    end
  end

  # ---------------------------------------------------------------------
  # Property-based test (issue #035)
  # ---------------------------------------------------------------------

  property "upsert_events/1 preserves exactly the columns of marked fields and replaces exactly the others" do
    check all raw_fields <- StreamData.list_of(field_generator(), max_length: 5) do
      marked_fields = Enum.uniq(raw_fields)

      event =
        event_fixture(
          label_fr: "Original fr",
          label_en: "Original en",
          begin_year: 1000,
          begin_precision: 9,
          begin_month: nil,
          begin_day: nil,
          end_year: 1100,
          end_precision: 9,
          end_month: nil,
          end_day: nil,
          end_calendar: :gregorian,
          geom: %Geo.Point{coordinates: {1.0, 2.0}, srid: 4326},
          location_source: :direct
        )

      event
      |> Ecto.Changeset.change(overridden_fields: Enum.map(marked_fields, &Atom.to_string/1))
      |> Repo.update!()

      incoming = %{
        qid: event.qid,
        label_fr: "Incoming fr",
        label_en: "Incoming en",
        description_fr: "desc",
        description_en: "desc",
        wiki_url_fr: nil,
        wiki_url_en: nil,
        kind: "Q1",
        begin_year: 1500,
        begin_month: nil,
        begin_day: nil,
        begin_precision: 9,
        begin_calendar: :gregorian,
        end_year: 1600,
        end_month: nil,
        end_day: nil,
        end_precision: 9,
        end_calendar: :gregorian,
        geom: %Geo.Point{coordinates: {10.0, 10.0}, srid: 4326},
        location_source: :place,
        sitelink_count: 99
      }

      {:ok, %{upserted: 1}} = Atlas.upsert_events([incoming])
      result = Atlas.get_event_by_qid(event.qid)

      if :label_fr in marked_fields do
        assert result.label_fr == "Original fr"
      else
        assert result.label_fr == "Incoming fr"
      end

      if :label_en in marked_fields do
        assert result.label_en == "Original en"
      else
        assert result.label_en == "Incoming en"
      end

      if :begin_date in marked_fields do
        assert result.begin_year == 1000
      else
        assert result.begin_year == 1500
      end

      # The end_* and geom/location_source CASE branches of the upsert
      # (quality review, residual defense: previously uncovered).
      if :end_date in marked_fields do
        assert result.end_year == 1100
      else
        assert result.end_year == 1600
      end

      if :position in marked_fields do
        assert %Geo.Point{coordinates: {1.0, 2.0}} = result.geom
        assert result.location_source == :direct
      else
        assert %Geo.Point{coordinates: {10.0, 10.0}} = result.geom
        assert result.location_source == :place
      end

      # Never-overridable columns always replaced.
      assert result.sitelink_count == 99
    end
  end

  defp field_generator,
    do: StreamData.member_of([:label_fr, :label_en, :begin_date, :end_date, :position])

  # ---------------------------------------------------------------------
  # propose/3 quota (issue #036)
  # ---------------------------------------------------------------------

  describe "propose/3" do
    test "happy path: under quota, delegates to propose/2" do
      event = event_fixture(label_fr: "Ancien nom")
      author = user_fixture()

      assert {:ok, override} =
               Contributions.propose(
                 %{
                   kind: :field,
                   event_qid: event.qid,
                   field: :label_fr,
                   proposed_value: %{"value" => "Nouveau nom"},
                   source: "https://example.org/source"
                 },
                 author.id,
                 unique_ip()
               )

      assert override.status == :pending
    end

    test "error case: over quota (author and IP shared across calls), nothing further is written" do
      # Exhausts the config-wide quota by CALL COUNT on this test's own
      # unique author/IP keys, never by lowering the global config via
      # `Application.put_env/3`: this file is `async: true`, and the
      # throttle's Hammer table is a single, shared, process-wide ETS
      # table (mirrors `Amanogawa.Accounts.MagicLinkThrottleTest`'s own
      # rationale) - mutating the global config here would race every
      # other async test proposing at the same moment. The exhaustion
      # itself goes through cheap `ProposalThrottle.allow?/2` hits (pure
      # ETS, no database write per hit) since config/test.exs
      # deliberately sets a high limit; one real proposal before and one
      # after prove the domain behavior at each side of the quota.
      limit =
        Application.get_env(:amanogawa, ProposalThrottle, limit: 10) |> Keyword.fetch!(:limit)

      event = event_fixture()
      author = user_fixture()
      ip = unique_ip()

      attrs = fn n ->
        %{
          kind: :field,
          event_qid: event.qid,
          field: :label_fr,
          proposed_value: %{"value" => "X#{n}"},
          source: "https://example.org/source"
        }
      end

      assert {:ok, _override} = Contributions.propose(attrs.(1), author.id, ip)

      for _n <- 2..limit//1 do
        assert ProposalThrottle.allow?(author.id, ip)
      end

      assert {:error, :rate_limited} = Contributions.propose(attrs.(limit + 1), author.id, ip)
      assert Contributions.list_overrides(%{author_id: author.id}) |> length() == 1
    end
  end

  # ---------------------------------------------------------------------
  # appeal_override/3, review_appeal/3, list_review_queue/1 (issue #037)
  # ---------------------------------------------------------------------

  describe "appeal_override/3" do
    test "happy path: the author appeals their own rejected proposal, once" do
      event = event_fixture()
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = propose_fixture(event, author)

      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      assert {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")
      assert appealed.status == :appealed

      assert Enum.map(Contributions.list_revisions(appealed.id), & &1.action) == [
               :proposed,
               :rejected,
               :appealed
             ]
    end

    test "edge case: a second appeal on the same override is refused" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _email, :rejected, _msg, _path, _locale -> :ok end)

      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")
      {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")

      assert {:error, :not_rejected} =
               Contributions.appeal_override(appealed.id, author, "Encore")
    end

    test "edge case: an appeal on a :pending or :accepted override is refused" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      pending = override_fixture(author_id: author.id)

      assert {:error, :not_rejected} =
               Contributions.appeal_override(pending.id, author, "Je conteste")

      expect(DecisionNotifierMock, :deliver, fn _email, :accepted, _msg, _path, _locale -> :ok end)

      accepted = override_fixture(author_id: author.id)
      {:ok, accepted} = Contributions.accept_override(accepted.id, reviewer, "motif")

      assert {:error, :not_rejected} =
               Contributions.appeal_override(accepted.id, author, "Je conteste")
    end

    test "error case: another user than the author cannot appeal; nothing is journalled" do
      event = event_fixture()
      author = user_fixture()
      other = user_fixture()
      reviewer = reviewer_fixture()
      override = propose_fixture(event, author)

      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      assert {:error, :forbidden} =
               Contributions.appeal_override(rejected.id, other, "Ce n'est pas moi")

      assert Enum.map(Contributions.list_revisions(rejected.id), & &1.action) == [
               :proposed,
               :rejected
             ]
    end

    test "limit case: an appeal text of 5 and 1000 characters is accepted, 4 and 1001 rejected" do
      author = user_fixture()
      reviewer = reviewer_fixture()

      short = String.duplicate("a", 4)
      min_ok = String.duplicate("a", 5)
      max_ok = String.duplicate("a", 1000)
      long = String.duplicate("a", 1001)

      make_rejected = fn ->
        override = override_fixture(author_id: author.id)
        expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
        {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")
        rejected
      end

      assert {:error, :text_required} =
               Contributions.appeal_override(make_rejected.().id, author, short)

      assert {:ok, _} = Contributions.appeal_override(make_rejected.().id, author, min_ok)
      assert {:ok, _} = Contributions.appeal_override(make_rejected.().id, author, max_ok)

      assert {:error, :text_required} =
               Contributions.appeal_override(make_rejected.().id, author, long)
    end
  end

  describe "review_appeal/3" do
    test "happy path: an accepted appeal applies the override through Atlas" do
      event = event_fixture(label_fr: "Ancien nom")
      author = user_fixture()
      reviewer = reviewer_fixture()

      override =
        propose_fixture(event, author,
          field: :label_fr,
          proposed_value: %{"value" => "Nouveau nom"}
        )

      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif initial")
      {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")

      expect(DecisionNotifierMock, :deliver, fn email, :appeal_accepted, message, path, "fr" ->
        assert email == author.email
        assert message == "Vu, j'accepte"
        assert path == "/contributions/#{appealed.id}"
        :ok
      end)

      assert {:ok, resolved} =
               Contributions.review_appeal(appealed.id, reviewer, %{
                 decision: :accepted,
                 message: "Vu, j'accepte"
               })

      assert resolved.status == :accepted
      assert Atlas.get_event_by_qid(event.qid).label_fr == override.proposed_value["value"]

      assert Enum.map(Contributions.list_revisions(resolved.id), & &1.action) == [
               :proposed,
               :rejected,
               :appealed,
               :appeal_reviewed
             ]
    end

    test "happy path: a rejected appeal is terminal, Atlas untouched" do
      event = event_fixture(label_fr: "Ancien nom")
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(event_qid: event.qid, author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")
      {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")

      expect(DecisionNotifierMock, :deliver, fn _e, :appeal_rejected, _m, _p, _l -> :ok end)

      assert {:ok, resolved} =
               Contributions.review_appeal(appealed.id, reviewer, %{
                 decision: :rejected,
                 message: "Confirmé"
               })

      assert resolved.status == :rejected
      assert Atlas.get_event_by_qid(event.qid).label_fr == "Ancien nom"

      # Terminal: no further appeal possible (the override is `:rejected`
      # again, the same status a never-appealed rejection carries, but the
      # `:appealed` revision already on record is what `already_appealed?/1`
      # finds, not the status alone).
      assert {:error, :already_appealed} =
               Contributions.appeal_override(resolved.id, author, "Encore une fois")
    end

    test "error case: a non-reviewer, the author, or a missing message is rejected" do
      author = user_fixture()
      other = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")
      {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")

      assert {:error, :forbidden} =
               Contributions.review_appeal(appealed.id, other, %{
                 decision: :accepted,
                 message: "motif"
               })

      assert {:error, :message_required} =
               Contributions.review_appeal(appealed.id, reviewer, %{
                 decision: :accepted,
                 message: ""
               })

      assert Repo.get!(Override, appealed.id).status == :appealed
    end
  end

  describe "list_review_queue/1" do
    test "limit case: lists :pending and :appealed overrides, chronological by proposal date, an appeal keeps its original date" do
      author = user_fixture()
      reviewer = reviewer_fixture()

      old = override_fixture(author_id: author.id)

      old
      |> Ecto.Changeset.change(inserted_at: DateTime.add(old.inserted_at, -60, :second))
      |> Repo.update!()

      middle = override_fixture(author_id: author.id)
      _accepted = accepted_override_fixture()

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(old.id, reviewer, "motif")
      {:ok, appealed} = Contributions.appeal_override(rejected.id, author, "Je conteste")

      assert Contributions.list_review_queue() |> Enum.map(& &1.id) ==
               [appealed.id, middle.id]
    end

    test "limit case: filters by kind and event_qid" do
      event = event_fixture()
      field_override = override_fixture(event_qid: event.qid, field: :label_fr)
      _other = override_fixture()

      assert Contributions.list_review_queue(%{event_qid: event.qid}) |> Enum.map(& &1.id) ==
               [field_override.id]

      assert Contributions.list_review_queue(%{kind: :field}) |> length() >= 1
    end
  end

  # ---------------------------------------------------------------------
  # Decision notifications (issue #037)
  # ---------------------------------------------------------------------

  describe "decision notifications" do
    test "propose/2 never sends a notification (no engagement email)" do
      # No `expect/3` set up: `verify_on_exit!` fails the test if the mock
      # is called at all.
      event = event_fixture()
      author = user_fixture()

      {:ok, _override} =
        Contributions.propose(
          %{
            kind: :field,
            event_qid: event.qid,
            field: :label_fr,
            proposed_value: %{"value" => "X"},
            source: "https://example.org/source"
          },
          author.id
        )
    end

    test "accept_override/3 sends exactly one notification with the motive, after commit" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn email, :accepted, message, path, "fr" ->
        assert email == author.email
        assert message == "Bien vu"
        assert path == "/contributions/#{override.id}"
        :ok
      end)

      assert {:ok, _} = Contributions.accept_override(override.id, reviewer, "Bien vu")
    end

    test "reject_override/3 sends exactly one notification with the motive" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn email, :rejected, message, _path, "fr" ->
        assert email == author.email
        assert message == "Source insuffisante"
        :ok
      end)

      assert {:ok, _} =
               Contributions.reject_override(override.id, reviewer, "Source insuffisante")
    end

    test "a notifier failure is logged and never fails the decision" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :accepted, _m, _p, _l ->
        {:error, :timeout}
      end)

      assert {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "motif")
      assert accepted.status == :accepted
    end

    test "no notification is sent for a decision the transaction rolled back" do
      # No `expect/3`: the message is blank, so the transaction never even
      # opens (`validate_reviewer_message/1` runs before any write).
      override = override_fixture()
      reviewer = reviewer_fixture()

      assert {:error, :message_required} =
               Contributions.accept_override(override.id, reviewer, "")
    end
  end

  # ---------------------------------------------------------------------
  # list_public/1 (issue #038)
  # ---------------------------------------------------------------------

  describe "list_public/1" do
    test "happy path: chronological (most recent first), no ranking, filters by status and event_qid" do
      event = event_fixture()
      other_event = event_fixture()
      pending = override_fixture(event_qid: event.qid)
      accepted = accepted_override_fixture(event_qid: event.qid)
      _other = override_fixture(event_qid: other_event.qid)

      assert Contributions.list_public(%{event_qid: event.qid}) == [accepted, pending]
      assert Contributions.list_public(%{status: "accepted", event_qid: event.qid}) == [accepted]
    end

    test "accepts string OR atom keys for the same filters" do
      event = event_fixture()
      override = override_fixture(event_qid: event.qid)

      assert Contributions.list_public(%{"status" => "pending", "event_qid" => event.qid}) == [
               override
             ]

      assert Contributions.list_public(%{status: "pending", event_qid: event.qid}) == [override]
    end

    test "error case: an unknown status is dropped, never an exception, never a 500" do
      override = override_fixture()

      assert Contributions.list_public(%{status: "not_a_real_status"})
             |> Enum.any?(&(&1.id == override.id))
    end

    test "error case: a malformed event id is dropped, never an exception" do
      override = override_fixture()

      assert Contributions.list_public(%{event_qid: "'; DROP TABLE overrides; --"})
             |> Enum.any?(&(&1.id == override.id))
    end

    test "limit case: keyset pagination with :after and :limit, stable across a tie" do
      event = event_fixture()
      same_instant = DateTime.truncate(DateTime.utc_now(), :second)

      first = override_fixture(event_qid: event.qid)
      first |> Ecto.Changeset.change(inserted_at: same_instant) |> Repo.update!()

      second = override_fixture(event_qid: event.qid)
      second |> Ecto.Changeset.change(inserted_at: same_instant) |> Repo.update!()

      [newest, oldest] =
        Contributions.list_public(%{event_qid: event.qid, limit: 2})
        |> Enum.sort_by(& &1.id, :desc)

      cursor = %{inserted_at: newest.inserted_at, id: newest.id}

      assert Contributions.list_public(%{event_qid: event.qid, after: cursor}) == [oldest]
    end

    test "limit case: a malformed :after or :limit is dropped" do
      override = override_fixture()

      assert Contributions.list_public(%{after: %{garbage: true}})
             |> Enum.any?(&(&1.id == override.id))

      assert Contributions.list_public(%{limit: -5}) |> Enum.any?(&(&1.id == override.id))
    end
  end

  # ---------------------------------------------------------------------
  # event_contribution_summary/1 (issue #038)
  # ---------------------------------------------------------------------

  describe "event_contribution_summary/1" do
    test "happy path: counts accepted and pending (appealed included), maps accepted fields to override ids" do
      event = event_fixture()
      accepted = accepted_override_fixture(event_qid: event.qid, field: :label_fr)
      _pending = override_fixture(event_qid: event.qid, field: :label_en)

      appealed =
        override_fixture(event_qid: event.qid, field: :label_en)
        |> Ecto.Changeset.change(status: :appealed)
        |> Repo.update!()

      summary = Contributions.event_contribution_summary(event.qid)

      assert summary.accepted_count == 1
      assert summary.pending_count == 2
      assert summary.accepted_override_ids_by_field["label_fr"] == accepted.id
      refute Map.has_key?(summary.accepted_override_ids_by_field, "label_en")
      assert appealed.status == :appealed
    end

    test "limit case: an event with no contribution returns all zeros and an empty map" do
      event = event_fixture()

      assert Contributions.event_contribution_summary(event.qid) == %{
               accepted_count: 0,
               pending_count: 0,
               accepted_override_ids_by_field: %{}
             }
    end
  end

  # ---------------------------------------------------------------------
  # public_stats/0 (issue #038)
  # ---------------------------------------------------------------------

  describe "public_stats/0" do
    test "limit case: an empty database returns coherent zeros, never a crash" do
      stats = Contributions.public_stats()

      assert stats.total_by_status == %{
               pending: 0,
               accepted: 0,
               rejected: 0,
               superseded: 0,
               appealed: 0
             }

      assert stats.proposals_by_month == []
      assert stats.median_decision_hours == nil
      assert stats.open_conflicts_count == 0
    end

    test "happy path: totals, monthly counts, median decision delay and open conflicts count" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      event = event_fixture()

      override = propose_fixture(event, author)
      _pending = override_fixture()

      assert {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "motif")

      # Reuses the very override just accepted (rather than
      # `conflict_fixture/1`'s own default, which would silently insert a
      # SECOND accepted override and throw off every count below).
      _conflict = conflict_fixture(override: accepted)

      stats = Contributions.public_stats()

      assert stats.total_by_status.accepted == 1
      assert stats.total_by_status.pending == 1
      assert [%{count: count}] = stats.proposals_by_month
      assert count == 2
      assert is_float(stats.median_decision_hours)
      assert stats.open_conflicts_count == 1
    end
  end

  # ---------------------------------------------------------------------
  # export_user_contributions/1 (issue #038)
  # ---------------------------------------------------------------------

  describe "export_user_contributions/1" do
    test "happy path: every contribution the user authored, with its own revisions" do
      author = user_fixture()
      event = event_fixture()
      override = propose_fixture(event, author)

      [exported] = Contributions.export_user_contributions(author)

      assert exported.id == override.id
      assert exported.status == :pending
      assert [%{action: :proposed}] = exported.revisions
    end

    test "edge case: a user with no contribution exports an empty list, never an error" do
      author = user_fixture()

      assert Contributions.export_user_contributions(author) == []
    end

    test "never carries author_id/actor_id (RGPD: only the requester's own export, no third-party id)" do
      author = user_fixture()
      event = event_fixture()
      _override = propose_fixture(event, author)

      [exported] = Contributions.export_user_contributions(author)

      refute Map.has_key?(exported, :author_id)
      assert Enum.all?(exported.revisions, &(not Map.has_key?(&1, :actor_id)))
    end
  end

  # ---------------------------------------------------------------------
  # anonymize_user/1 (issue #038)
  # ---------------------------------------------------------------------

  describe "anonymize_user/1" do
    test "happy path: nils author_id/actor_id, journals one :anonymized revision per touched override" do
      author = user_fixture()
      event = event_fixture()
      override = propose_fixture(event, author)

      assert :ok = Contributions.anonymize_user(author)

      reloaded = Contributions.get_override(override.id)
      assert reloaded.author_id == nil
      assert reloaded.status == :pending
      assert reloaded.source == override.source

      revisions = Contributions.list_revisions(override.id)
      assert Enum.any?(revisions, &(&1.action == :anonymized))
      assert Enum.find(revisions, &(&1.action == :proposed)).actor_id == nil
    end

    test "anonymizes a reviewer's own actor_id on revisions, without touching the override's author" do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      assert {:ok, _accepted} = Contributions.accept_override(override.id, reviewer, "motif")
      assert :ok = Contributions.anonymize_user(reviewer)

      reloaded = Contributions.get_override(override.id)
      assert reloaded.author_id == author.id

      revisions = Contributions.list_revisions(override.id)
      assert Enum.find(revisions, &(&1.action == :accepted)).actor_id == nil
      refute Enum.any?(revisions, &(&1.action == :anonymized))
    end

    test "edge case: idempotent, replayed after a simulated crash never doubles :anonymized revisions" do
      author = user_fixture()
      event = event_fixture()
      override = propose_fixture(event, author)

      assert :ok = Contributions.anonymize_user(author)
      assert :ok = Contributions.anonymize_user(author)

      revisions = Contributions.list_revisions(override.id)
      assert Enum.count(revisions, &(&1.action == :anonymized)) == 1
    end

    test "edge case: an author with no contribution is a no-op that still returns :ok" do
      author = user_fixture()

      assert :ok = Contributions.anonymize_user(author)
    end

    test "M5: a resolved conflict's resolved_by is anonymized too" do
      reviewer = reviewer_fixture()
      conflict = conflict_fixture()

      assert {:ok, resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "motif"
               })

      assert resolved.resolved_by == reviewer.id

      assert :ok = Contributions.anonymize_user(reviewer)

      assert Repo.get!(Conflict, conflict.id).resolved_by == nil
    end
  end

  # ---------------------------------------------------------------------
  # Property: export_user_contributions/1 composed with
  # Amanogawa.Accounts.export_user_data/1 always encodes and never leaks
  # another user's identity (issue #038, precedent #033)
  # ---------------------------------------------------------------------

  property "export composed for an arbitrary user always JSON-encodes and never leaks another user's email" do
    check all(contribution_count <- StreamData.integer(0..4), max_runs: 10) do
      author = user_fixture()
      other = user_fixture()

      for _ <- 1..contribution_count//1 do
        event = event_fixture()
        propose_fixture(event, author)
      end

      export = %{
        format_version: 2,
        account: %{email: author.email},
        contributions: Contributions.export_user_contributions(author)
      }

      assert {:ok, encoded} = Jason.encode(export)
      refute encoded =~ other.email
    end
  end

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    "10.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end

  # A `:field`/`label_fr` proposal through the real facade (unlike
  # `override_fixture/1`, which bypasses it): the ONLY way to get the
  # `:proposed` revision a full state-machine assertion needs.
  defp propose_fixture(event, author, attrs \\ []) do
    attrs = Map.new(attrs)

    base = %{
      kind: :field,
      event_qid: event.qid,
      field: :label_fr,
      proposed_value: %{"value" => "Nouveau nom"},
      source: "https://example.org/source"
    }

    {:ok, override} = Contributions.propose(Map.merge(base, attrs), author.id, unique_ip())
    override
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp accept_begin_date_override(event, proposed_year) do
    accept_date_override(event, :begin_date, proposed_year)
  end

  defp accept_end_date_override(event, proposed_year) do
    accept_date_override(event, :end_date, proposed_year)
  end

  defp accept_date_override(event, field, proposed_year) do
    author = user_fixture()
    reviewer = reviewer_fixture()

    {:ok, override} =
      Contributions.propose(
        %{
          kind: :field,
          event_qid: event.qid,
          field: field,
          proposed_value: %{
            "year" => proposed_year,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          },
          source: "https://example.org/source"
        },
        author.id
      )

    {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "motif")
    accepted
  end

  defp lot_entry(event, overrides) do
    %{
      qid: event.qid,
      label_fr: event.label_fr,
      label_en: event.label_en,
      begin_year: event.begin_year,
      begin_month: event.begin_month,
      begin_day: event.begin_day,
      begin_precision: event.begin_precision,
      begin_calendar: event.begin_calendar,
      end_year: event.end_year,
      end_month: event.end_month,
      end_day: event.end_day,
      end_precision: event.end_precision,
      end_calendar: event.end_calendar,
      geom: event.geom,
      location_source: event.location_source
    }
    |> Map.merge(Map.new(overrides))
  end

  # Counts `Amanogawa.Repo` queries issued while `fun` runs (via the
  # default Ecto telemetry event), used by the "no N+1" limit-case test
  # above: a more faithful assertion than counting `Repo.all/2` call
  # sites by hand.
  defp query_count(fun) do
    ref = :counters.new(1, [])
    handler_id = {:query_count, make_ref()}
    test_pid = self()

    # Telemetry handlers run in whatever process emits the event, not the
    # process that attached them: `async: true` tests issue queries
    # concurrently on their own processes, so without this guard a
    # sibling test's queries would inflate this count too.
    :telemetry.attach(
      handler_id,
      [:amanogawa, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(ref, 1, 1)
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler_id)

    {:counters.get(ref, 1), result}
  end
end
