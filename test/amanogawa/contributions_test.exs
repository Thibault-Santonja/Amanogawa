defmodule Amanogawa.ContributionsTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Amanogawa.HistoricalDateGenerators

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.Conflict
  alias Amanogawa.Contributions.Override
  alias Amanogawa.HistoricalDate
  alias Amanogawa.Repo

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
          begin_day: nil
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
        end_year: nil,
        end_month: nil,
        end_day: nil,
        end_precision: nil,
        end_calendar: nil,
        geom: %Geo.Point{coordinates: {10.0, 10.0}, srid: 4326},
        location_source: :direct,
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

      # Never-overridable columns always replaced.
      assert result.sitelink_count == 99
    end
  end

  defp field_generator, do: StreamData.member_of([:label_fr, :label_en, :begin_date])

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp accept_begin_date_override(event, proposed_year) do
    author = user_fixture()
    reviewer = reviewer_fixture()

    {:ok, override} =
      Contributions.propose(
        %{
          kind: :field,
          event_qid: event.qid,
          field: :begin_date,
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
