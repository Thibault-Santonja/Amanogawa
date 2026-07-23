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

      first_rows = all_events_comparable()

      assert {:ok, %{upserted: 2}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 2

      # The full structs must survive the replay unchanged; only updated_at
      # (touched by the upsert) may differ.
      assert all_events_comparable() == first_rows
    end

    test "a batch repeating the same QID is deduplicated instead of crashing the statement" do
      events = [
        event_attrs(qid: "Q1", label_fr: "Premier"),
        event_attrs(qid: "Q1", label_fr: "Doublon"),
        event_attrs(qid: "Q2")
      ]

      assert {:ok, %{upserted: 2}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 2
      # First occurrence wins.
      assert Atlas.get_event_by_qid("Q1").label_fr == "Premier"
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

    test "a batch repeating the same pair is deduplicated within the batch (exact created count)" do
      event_fixture(qid: "Q1")
      event_fixture(qid: "Q2")

      links = [
        %{source_qid: "Q1", target_qid: "Q2", type: :part_of},
        %{source_qid: "Q1", target_qid: "Q2", type: :part_of}
      ]

      assert {:ok, %{created: 1, skipped_missing: 0}} = Atlas.upsert_event_links(links)
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

  describe "get_event_summary/1" do
    test "happy path: full summary with fr extract and thumbnail" do
      event_fixture(
        qid: "Q1",
        label_fr: "Bataille de Marathon",
        label_en: "Battle of Marathon",
        extract_fr: "Resume francais",
        extract_en: "English summary",
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
        wiki_url_en: "https://en.wikipedia.org/wiki/Battle_of_Marathon",
        thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg",
        extract_fetched_at: ~U[2026-01-01 00:00:00Z]
      )

      assert {:ok, summary} = Atlas.get_event_summary("Q1")

      assert summary == %{
               qid: "Q1",
               label: "Bataille de Marathon",
               extract: "Resume francais",
               thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg",
               wiki_url: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
               extract_language: "fr",
               fetched_at: ~U[2026-01-01 00:00:00Z]
             }
    end

    test "edge case: falls back to English label, extract and wiki_url when French is absent" do
      event_fixture(
        qid: "Q1",
        label_fr: nil,
        label_en: "Battle of Marathon",
        extract_fr: nil,
        extract_en: "English summary",
        wiki_url_fr: nil,
        wiki_url_en: "https://en.wikipedia.org/wiki/Battle_of_Marathon"
      )

      assert {:ok, summary} = Atlas.get_event_summary("Q1")

      assert summary.label == "Battle of Marathon"
      assert summary.extract == "English summary"
      assert summary.extract_language == "en"
      assert summary.wiki_url == "https://en.wikipedia.org/wiki/Battle_of_Marathon"
    end

    test "edge case: an event without an extract yet returns extract and extract_language as nil" do
      event_fixture(qid: "Q1", extract_fr: nil, extract_en: nil)

      assert {:ok, summary} = Atlas.get_event_summary("Q1")

      assert summary.extract == nil
      assert summary.extract_language == nil
    end

    test "edge case: an event without a thumbnail returns thumbnail_url as nil" do
      event_fixture(qid: "Q1", thumbnail_url: nil)

      assert {:ok, summary} = Atlas.get_event_summary("Q1")

      assert summary.thumbnail_url == nil
    end

    test "error case: an unknown QID returns :not_found" do
      assert Atlas.get_event_summary("Q999999999") == {:error, :not_found}
    end
  end

  describe "list_event_links_geojson/1" do
    test "happy path: a mix of outgoing and incoming relations, correctly oriented" do
      center =
        event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326})

      target =
        event_fixture(
          qid: "Q2",
          label_fr: "Cible",
          begin_year: 500,
          geom: %Geo.Point{coordinates: {12.5, 41.9}, srid: 4326}
        )

      source =
        event_fixture(
          qid: "Q3",
          label_fr: "Source",
          begin_year: -100,
          geom: %Geo.Point{coordinates: {-3.7, 40.4}, srid: 4326}
        )

      event_link_fixture(source_id: center.id, target_id: target.id, type: :cause)
      event_link_fixture(source_id: source.id, target_id: center.id, type: :follows)

      assert {:ok, %{"type" => "FeatureCollection", "features" => features}} =
               Atlas.list_event_links_geojson("Q1")

      assert length(features) == 2

      outgoing = Enum.find(features, &(&1["properties"]["direction"] == "outgoing"))
      incoming = Enum.find(features, &(&1["properties"]["direction"] == "incoming"))

      assert outgoing["type"] == "Feature"
      assert outgoing["geometry"]["type"] == "LineString"

      assert outgoing["geometry"]["coordinates"] == [
               [2.35, 48.85],
               [12.5, 41.9]
             ]

      assert outgoing["properties"] == %{
               "link_type" => "cause",
               "direction" => "outgoing",
               "target_qid" => "Q2",
               "target_label" => "Cible",
               "target_year" => 500
             }

      assert incoming["geometry"]["coordinates"] == [
               [2.35, 48.85],
               [-3.7, 40.4]
             ]

      assert incoming["properties"] == %{
               "link_type" => "follows",
               "direction" => "incoming",
               "target_qid" => "Q3",
               "target_label" => "Source",
               "target_year" => -100
             }
    end

    test "edge case: a relation whose target has no geometry is excluded without error" do
      center = event_fixture(qid: "Q1")
      target = event_fixture(qid: "Q2", geom: nil)

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => []}} = Atlas.list_event_links_geojson("Q1")
    end

    test "edge case: an event without any relation returns an empty FeatureCollection" do
      event_fixture(qid: "Q1")

      assert {:ok, %{"type" => "FeatureCollection", "features" => []}} =
               Atlas.list_event_links_geojson("Q1")
    end

    test "edge case: the target label falls back to English when French is absent" do
      center = event_fixture(qid: "Q1")
      target = event_fixture(qid: "Q2", label_fr: nil, label_en: "English only")

      event_link_fixture(source_id: center.id, target_id: target.id, type: :significant)

      assert {:ok, %{"features" => [feature]}} = Atlas.list_event_links_geojson("Q1")
      assert feature["properties"]["target_label"] == "English only"
    end

    test "edge case: the selected event itself has no geometry: empty collection, no error" do
      center = event_fixture(qid: "Q1", geom: nil)
      target = event_fixture(qid: "Q2")

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => []}} = Atlas.list_event_links_geojson("Q1")
    end

    test "limit case: a highly connected event returns every well-formed relation" do
      center = event_fixture(qid: "Q1")

      for i <- 1..40 do
        target = event_fixture(qid: "Q#{i + 1}")
        event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)
      end

      assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson("Q1")
      assert length(features) == 40
      assert Enum.all?(features, &(&1["geometry"]["type"] == "LineString"))
    end

    test "limit case: two endpoints at the same point are kept as a degenerate LineString" do
      point = %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326}
      center = event_fixture(qid: "Q1", geom: point)
      target = event_fixture(qid: "Q2", geom: point)

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => [feature]}} = Atlas.list_event_links_geojson("Q1")
      assert feature["geometry"]["coordinates"] == [[2.35, 48.85], [2.35, 48.85]]
    end

    test "error case: an unknown QID returns :not_found" do
      assert Atlas.list_event_links_geojson("Q999999999") == {:error, :not_found}
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

  # Every event row stripped of what a legitimate replay may touch, keyed
  # by qid: only updated_at changes on an idempotent upsert.
  defp all_events_comparable do
    Event
    |> Repo.all()
    |> Map.new(fn event ->
      {event.qid, event |> Map.from_struct() |> Map.drop([:__meta__, :updated_at])}
    end)
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
