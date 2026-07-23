defmodule Amanogawa.AtlasTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Repo

  describe "upsert_events/1" do
    test "inserting a batch and replaying it leaves row count and columns unchanged (idempotence)" do
      events = [event_attrs(qid: "Q1"), event_attrs(qid: "Q2")]

      assert {:ok, %{upserted: 2}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 2

      assert {:ok, %{upserted: 2}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 2
    end

    test "a modified label updates the existing row instead of duplicating it" do
      {:ok, _} = Atlas.upsert_events([event_attrs(qid: "Q1", label_fr: "Ancien nom")])
      {:ok, _} = Atlas.upsert_events([event_attrs(qid: "Q1", label_fr: "Nouveau nom")])

      assert Atlas.count_events() == 1
      assert Atlas.get_event_by_qid("Q1").label_fr == "Nouveau nom"
    end

    test "a Wikidata upsert does not overwrite an existing extract_fr" do
      {:ok, _} = Atlas.upsert_events([event_attrs(qid: "Q1")])

      Atlas.get_event_by_qid("Q1")
      |> Ecto.Changeset.change(extract_fr: "Resume Wikipedia")
      |> Repo.update!()

      {:ok, _} = Atlas.upsert_events([event_attrs(qid: "Q1", label_fr: "Nom mis a jour")])

      updated = Atlas.get_event_by_qid("Q1")
      assert updated.label_fr == "Nom mis a jour"
      assert updated.extract_fr == "Resume Wikipedia"
    end

    test "a batch of more than 500 elements is accepted (chunked insert_all)" do
      events = for i <- 1..600, do: event_attrs(qid: "Q#{i}")

      assert {:ok, %{upserted: 600}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 600
    end

    test "accepts string-keyed rows, as normalized data may come with either key type" do
      row = event_attrs(qid: "Q1") |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      assert {:ok, %{upserted: 1}} = Atlas.upsert_events([row])
      assert Atlas.get_event_by_qid("Q1")
    end
  end

  describe "upsert_event_links/1" do
    test "creates links for pairs whose QIDs both exist locally, skips the rest" do
      event_fixture(qid: "Q1")
      event_fixture(qid: "Q2")

      links = [
        %{source_qid: "Q1", target_qid: "Q2", type: :part_of},
        %{source_qid: "Q1", target_qid: "Q999", type: :follows}
      ]

      assert {:ok, %{created: 1, skipped_missing: 1}} = Atlas.upsert_event_links(links)
      assert Atlas.count_event_links() == 1
    end

    test "replaying the same batch creates no duplicate (unique constraint + on_conflict: :nothing)" do
      event_fixture(qid: "Q1")
      event_fixture(qid: "Q2")

      links = [%{source_qid: "Q1", target_qid: "Q2", type: :part_of}]

      assert {:ok, %{created: 1, skipped_missing: 0}} = Atlas.upsert_event_links(links)
      assert {:ok, %{created: 0, skipped_missing: 0}} = Atlas.upsert_event_links(links)
      assert Atlas.count_event_links() == 1
    end
  end

  describe "get_event_by_qid/1 and event_ids_by_qids/1" do
    test "returns nil / omits unknown QIDs" do
      event_fixture(qid: "Q1")

      assert Atlas.get_event_by_qid("Q999") == nil
      assert Atlas.event_ids_by_qids(["Q1", "Q999"]) |> Map.keys() == ["Q1"]
    end
  end

  describe "indexes and constraints" do
    test "qid has a unique constraint" do
      event_fixture(qid: "Q1")

      assert {:error, changeset} =
               %Event{}
               |> Event.changeset(event_attrs(qid: "Q1"))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).qid
    end

    test "events.geom has a GiST index" do
      assert index_exists?("atlas", "events", "gist")
    end
  end

  defp index_exists?(schema, table, using) do
    query = """
    SELECT 1 FROM pg_indexes
    WHERE schemaname = $1 AND tablename = $2 AND indexdef ILIKE $3
    """

    %{rows: rows} = Repo.query!(query, [schema, table, "%USING #{using}%"])
    rows != []
  end

  defp event_attrs(overrides) do
    %{
      qid: "Q0",
      label_fr: "Evenement de test",
      begin_year: 1789,
      begin_precision: 9,
      location_source: :direct,
      sitelink_count: 0,
      geom: %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326}
    }
    |> Map.merge(Map.new(overrides))
  end
end
