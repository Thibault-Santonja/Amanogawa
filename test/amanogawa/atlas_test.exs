defmodule Amanogawa.AtlasTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Atlas.TimeScale
  alias Amanogawa.Repo

  describe "upsert_events/1" do
    test "inserting a batch and replaying it leaves row count and columns unchanged (idempotence)" do
      events = unique_qids(2) |> Enum.map(&event_attrs(qid: &1))

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
      [qid_1, qid_2] = unique_qids(2)

      events = [
        event_attrs(qid: qid_1, label_fr: "Premier"),
        event_attrs(qid: qid_1, label_fr: "Doublon"),
        event_attrs(qid: qid_2)
      ]

      assert {:ok, %{upserted: 2}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 2
      # First occurrence wins.
      assert Atlas.get_event_by_qid(qid_1).label_fr == "Premier"
    end

    test "a modified label updates the existing row instead of duplicating it" do
      qid = hd(unique_qids(1))

      {:ok, _} = Atlas.upsert_events([event_attrs(qid: qid, label_fr: "Ancien nom")])
      {:ok, _} = Atlas.upsert_events([event_attrs(qid: qid, label_fr: "Nouveau nom")])

      assert Atlas.count_events() == 1
      assert Atlas.get_event_by_qid(qid).label_fr == "Nouveau nom"
    end

    test "a Wikidata upsert does not overwrite an existing extract_fr" do
      qid = hd(unique_qids(1))

      {:ok, _} = Atlas.upsert_events([event_attrs(qid: qid)])

      Atlas.get_event_by_qid(qid)
      |> Ecto.Changeset.change(extract_fr: "Resume Wikipedia")
      |> Repo.update!()

      {:ok, _} = Atlas.upsert_events([event_attrs(qid: qid, label_fr: "Nom mis a jour")])

      updated = Atlas.get_event_by_qid(qid)
      assert updated.label_fr == "Nom mis a jour"
      assert updated.extract_fr == "Resume Wikipedia"
    end

    test "a batch of more than 500 elements is accepted (chunked insert_all)" do
      events = unique_qids(600) |> Enum.map(&event_attrs(qid: &1))

      assert {:ok, %{upserted: 600}} = Atlas.upsert_events(events)
      assert Atlas.count_events() == 600
    end

    test "accepts string-keyed rows, as normalized data may come with either key type" do
      qid = hd(unique_qids(1))
      row = event_attrs(qid: qid) |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      assert {:ok, %{upserted: 1}} = Atlas.upsert_events([row])
      assert Atlas.get_event_by_qid(qid)
    end
  end

  describe "upsert_event_links/1" do
    test "creates links for pairs whose QIDs both exist locally, skips the rest" do
      [qid_1, qid_2, never_inserted_qid] = unique_qids(3)
      event_fixture(qid: qid_1)
      event_fixture(qid: qid_2)

      links = [
        %{source_qid: qid_1, target_qid: qid_2, type: :part_of},
        %{source_qid: qid_1, target_qid: never_inserted_qid, type: :follows}
      ]

      assert {:ok, %{created: 1, skipped_missing: 1}} = Atlas.upsert_event_links(links)
      assert Atlas.count_event_links() == 1
    end

    test "replaying the same batch creates no duplicate (unique constraint + on_conflict: :nothing)" do
      [qid_1, qid_2] = unique_qids(2)
      event_fixture(qid: qid_1)
      event_fixture(qid: qid_2)

      links = [%{source_qid: qid_1, target_qid: qid_2, type: :part_of}]

      assert {:ok, %{created: 1, skipped_missing: 0}} = Atlas.upsert_event_links(links)
      assert {:ok, %{created: 0, skipped_missing: 0}} = Atlas.upsert_event_links(links)
      assert Atlas.count_event_links() == 1
    end

    test "a batch repeating the same pair is deduplicated within the batch (exact created count)" do
      [qid_1, qid_2] = unique_qids(2)
      event_fixture(qid: qid_1)
      event_fixture(qid: qid_2)

      links = [
        %{source_qid: qid_1, target_qid: qid_2, type: :part_of},
        %{source_qid: qid_1, target_qid: qid_2, type: :part_of}
      ]

      assert {:ok, %{created: 1, skipped_missing: 0}} = Atlas.upsert_event_links(links)
      assert Atlas.count_event_links() == 1
    end
  end

  describe "get_event_by_qid/1 and event_ids_by_qids/1" do
    test "returns nil / omits unknown QIDs" do
      [qid, never_inserted_qid] = unique_qids(2)
      event_fixture(qid: qid)

      assert Atlas.get_event_by_qid(never_inserted_qid) == nil
      assert Atlas.event_ids_by_qids([qid, never_inserted_qid]) |> Map.keys() == [qid]
    end
  end

  describe "get_event_summary/1" do
    test "happy path: full summary with fr extract and thumbnail" do
      qid = hd(unique_qids(1))

      event_fixture(
        qid: qid,
        label_fr: "Bataille de Marathon",
        label_en: "Battle of Marathon",
        extract_fr: "Resume francais",
        extract_en: "English summary",
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
        wiki_url_en: "https://en.wikipedia.org/wiki/Battle_of_Marathon",
        thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg",
        extract_fetched_at: ~U[2026-01-01 00:00:00Z]
      )

      assert {:ok, summary} = Atlas.get_event_summary(qid)

      assert summary == %{
               qid: qid,
               label: "Bataille de Marathon",
               extract: "Resume francais",
               thumbnail_url: "https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg",
               wiki_url: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
               extract_language: "fr",
               fetched_at: ~U[2026-01-01 00:00:00Z]
             }
    end

    test "edge case: falls back to English label, extract and wiki_url when French is absent" do
      qid = hd(unique_qids(1))

      event_fixture(
        qid: qid,
        label_fr: nil,
        label_en: "Battle of Marathon",
        extract_fr: nil,
        extract_en: "English summary",
        wiki_url_fr: nil,
        wiki_url_en: "https://en.wikipedia.org/wiki/Battle_of_Marathon"
      )

      assert {:ok, summary} = Atlas.get_event_summary(qid)

      assert summary.label == "Battle of Marathon"
      assert summary.extract == "English summary"
      assert summary.extract_language == "en"
      assert summary.wiki_url == "https://en.wikipedia.org/wiki/Battle_of_Marathon"
    end

    test "edge case: an event without an extract yet returns extract and extract_language as nil" do
      qid = hd(unique_qids(1))
      event_fixture(qid: qid, extract_fr: nil, extract_en: nil)

      assert {:ok, summary} = Atlas.get_event_summary(qid)

      assert summary.extract == nil
      assert summary.extract_language == nil
    end

    test "edge case: an event without a thumbnail returns thumbnail_url as nil" do
      qid = hd(unique_qids(1))
      event_fixture(qid: qid, thumbnail_url: nil)

      assert {:ok, summary} = Atlas.get_event_summary(qid)

      assert summary.thumbnail_url == nil
    end

    test "error case: an unknown QID returns :not_found" do
      assert Atlas.get_event_summary("Q999999999") == {:error, :not_found}
    end
  end

  describe "list_event_links_geojson/1" do
    test "happy path: a mix of outgoing and incoming relations, correctly oriented" do
      [center_qid, target_qid, source_qid] = unique_qids(3)

      center =
        event_fixture(qid: center_qid, geom: %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326})

      target =
        event_fixture(
          qid: target_qid,
          label_fr: "Cible",
          begin_year: 500,
          geom: %Geo.Point{coordinates: {12.5, 41.9}, srid: 4326}
        )

      source =
        event_fixture(
          qid: source_qid,
          label_fr: "Source",
          begin_year: -100,
          geom: %Geo.Point{coordinates: {-3.7, 40.4}, srid: 4326}
        )

      event_link_fixture(source_id: center.id, target_id: target.id, type: :cause)
      event_link_fixture(source_id: source.id, target_id: center.id, type: :follows)

      assert {:ok, %{"type" => "FeatureCollection", "features" => features}} =
               Atlas.list_event_links_geojson(center_qid)

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
               "target_qid" => target_qid,
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
               "target_qid" => source_qid,
               "target_label" => "Source",
               "target_year" => -100
             }
    end

    test "edge case: a relation whose target has no geometry is excluded without error" do
      [center_qid, target_qid] = unique_qids(2)
      center = event_fixture(qid: center_qid)
      target = event_fixture(qid: target_qid, geom: nil)

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => []}} = Atlas.list_event_links_geojson(center_qid)
    end

    test "edge case: an event without any relation returns an empty FeatureCollection" do
      qid = hd(unique_qids(1))
      event_fixture(qid: qid)

      assert {:ok, %{"type" => "FeatureCollection", "features" => []}} =
               Atlas.list_event_links_geojson(qid)
    end

    test "edge case: the target label falls back to English when French is absent" do
      [center_qid, target_qid] = unique_qids(2)
      center = event_fixture(qid: center_qid)
      target = event_fixture(qid: target_qid, label_fr: nil, label_en: "English only")

      event_link_fixture(source_id: center.id, target_id: target.id, type: :significant)

      assert {:ok, %{"features" => [feature]}} = Atlas.list_event_links_geojson(center_qid)
      assert feature["properties"]["target_label"] == "English only"
    end

    test "edge case: the selected event itself has no geometry: empty collection, no error" do
      [center_qid, target_qid] = unique_qids(2)
      center = event_fixture(qid: center_qid, geom: nil)
      target = event_fixture(qid: target_qid)

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => []}} = Atlas.list_event_links_geojson(center_qid)
    end

    test "limit case: a highly connected event returns every well-formed relation" do
      [center_qid | target_qids] = unique_qids(41)
      center = event_fixture(qid: center_qid)

      for target_qid <- target_qids do
        target = event_fixture(qid: target_qid)
        event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)
      end

      assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson(center_qid)
      assert length(features) == 40
      assert Enum.all?(features, &(&1["geometry"]["type"] == "LineString"))
    end

    test "limit case: two endpoints at the same point are kept as a degenerate LineString" do
      [center_qid, target_qid] = unique_qids(2)
      point = %Geo.Point{coordinates: {2.35, 48.85}, srid: 4326}
      center = event_fixture(qid: center_qid, geom: point)
      target = event_fixture(qid: target_qid, geom: point)

      event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)

      assert {:ok, %{"features" => [feature]}} = Atlas.list_event_links_geojson(center_qid)
      assert feature["geometry"]["coordinates"] == [[2.35, 48.85], [2.35, 48.85]]
    end

    test "error case: an unknown QID returns :not_found" do
      assert Atlas.list_event_links_geojson("Q999999999") == {:error, :not_found}
    end
  end

  describe "event_histogram/1" do
    test "happy path: returns a dense list of buckets summing to the matching event count" do
      event_fixture(begin_year: -100)
      event_fixture(begin_year: 500)
      event_fixture(begin_year: 1789)

      result = Atlas.event_histogram(%{from: -1000, to: 2000, buckets: 5})

      assert result["from"] == -1000
      assert result["to"] == 2000
      assert length(result["buckets"]) == 5
      assert Enum.sum(Enum.map(result["buckets"], & &1["count"])) == 3
    end

    test "happy path: bucket edges are strictly increasing and start/end at the requested window" do
      result = Atlas.event_histogram(%{from: -10_000, to: 2000, buckets: 8})
      buckets = result["buckets"]

      edges = [hd(buckets)["from"] | Enum.map(buckets, & &1["to"])]
      assert edges == Enum.sort(edges)

      assert hd(buckets)["from"] == -10_000
      assert List.last(buckets)["to"] == 2000
    end

    test "edge case: an empty window yields a dense list of zero-count buckets" do
      result = Atlas.event_histogram(%{from: -1000, to: 2000, buckets: 4})

      # Edges are equidistant in symlog *position* space, not in years
      # (`Amanogawa.Atlas.TimeScale`'s whole point): computed independently
      # here via `TimeScale.year/2` rather than hardcoded, so the test does
      # not silently ossify a wrong assumption of linear spacing.
      scale = TimeScale.default()
      low = TimeScale.position(scale, -1000)
      high = TimeScale.position(scale, 2000)

      expected_edges =
        [-1000] ++
          Enum.map(1..3, fn i -> TimeScale.year(scale, low + i * (high - low) / 4) end) ++
          [2000]

      expected_buckets =
        expected_edges
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to, "count" => 0} end)

      assert result["buckets"] == expected_buckets
    end

    test "edge case: an event exactly on a bucket boundary is assigned deterministically" do
      event_fixture(begin_year: 2000)

      result = Atlas.event_histogram(%{from: 0, to: 2000, buckets: 4})

      assert List.last(result["buckets"])["count"] == 1
      assert Enum.sum(Enum.map(result["buckets"], & &1["count"])) == 1
    end

    test "limit case: buckets=1 returns a single bucket spanning the whole window" do
      event_fixture(begin_year: 0)

      result = Atlas.event_histogram(%{from: -1000, to: 2000, buckets: 1})

      assert [%{"from" => -1000, "to" => 2000, "count" => 1}] = result["buckets"]
    end

    test "limit case: buckets=200 over the full domain returns exactly 200 dense buckets" do
      result =
        Atlas.event_histogram(%{from: -300_000, to: TimeScale.current_year(), buckets: 200})

      assert length(result["buckets"]) == 200
    end

    # A window whose span comfortably exceeds its bucket count (at least 50
    # years/bucket) so the integer-year rounding of interior edges never
    # collapses two consecutive positions to the same year: below that
    # margin, the aliasing is an inherent, documented property of
    # quantizing a continuous position to whole years
    # (`Amanogawa.Atlas.TimeScale`'s moduledoc), not a bug this property
    # is meant to catch.
    property "Property (alignment): bucket edges are strictly increasing and their positions are equidistant" do
      scale = TimeScale.default()

      check all buckets <- integer(1..50),
                span <- integer((buckets * 50)..250_000),
                from <- integer(scale.min_year..(scale.max_year - span)),
                max_runs: 25 do
        to = from + span

        result = Atlas.event_histogram(%{from: from, to: to, buckets: buckets})
        edges = [hd(result["buckets"])["from"] | Enum.map(result["buckets"], & &1["to"])]

        assert edges == Enum.sort(edges)
        assert edges == Enum.uniq(edges)

        positions = Enum.map(edges, &TimeScale.position(scale, &1))
        deltas = positions |> Enum.chunk_every(2, 1, :discard) |> Enum.map(fn [a, b] -> b - a end)
        avg_delta = (List.last(positions) - hd(positions)) / buckets

        # Floating tolerance, not a strict equality: the interior edges are
        # rounded to whole years before their position is recomputed here,
        # so each delta only approximates `avg_delta`, especially deep in
        # the symlog-compressed past where a single year covers a
        # comparatively large slice of position space.
        assert Enum.all?(deltas, &(abs(&1 - avg_delta) <= avg_delta * 0.5 + 1.0e-6))
      end
    end
  end

  describe "format_axis_year/2 and /3" do
    test "delegates to Amanogawa.Atlas.TimeScale.Format" do
      assert Atlas.format_axis_year(1969, 1) == "1969"
      assert Atlas.format_axis_year(-750, 100) == "VIIIe s. av. J.-C."
    end

    test "the /3 arity renders through caller-provided templates (F04 quality finding m6)" do
      templates = %{ka_bp: "%{ka} ka BP", century: "%{century}th c.", bce: "%{text} BCE"}

      assert Atlas.format_axis_year(-750, 100, templates) == "VIIIth c. BCE"
      assert Atlas.format_axis_year(-489, 1, templates) == "490 BCE"
    end
  end

  describe "upsert_polity/1" do
    test "happy path: inserts a fresh polity" do
      assert {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      assert polity.name == "Roman Empire"
      assert Atlas.count_polities() == 1
    end

    test "edge case: replaying the same (name, source) updates from_year/to_year, keeps the id" do
      {:ok, first} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})

      {:ok, second} =
        Atlas.upsert_polity(%{
          name: "Roman Empire",
          source: "cliopatria",
          from_year: -27,
          to_year: 476
        })

      assert second.id == first.id
      assert second.from_year == -27
      assert second.to_year == 476
      assert Atlas.count_polities() == 1
    end

    test "edge case: the same name under a different source is a distinct row" do
      {:ok, _} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      {:ok, _} = Atlas.upsert_polity(%{name: "Roman Empire", source: "historical_basemaps"})

      assert Atlas.count_polities() == 2
    end

    test "error case: a missing name returns a changeset error" do
      assert {:error, changeset} = Atlas.upsert_polity(%{source: "cliopatria"})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "replace_borders/2" do
    @square %{
      "type" => "Polygon",
      "coordinates" => [[[0.0, 0.0], [0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]]]
    }

    defp border_row(polity_id, overrides \\ %{}) do
      Map.merge(
        %{
          polity_id: polity_id,
          geometry: @square,
          from_year: -100,
          to_year: 100,
          source: "cliopatria",
          precision: nil
        },
        overrides
      )
    end

    test "happy path: purges the source and inserts the given rows" do
      {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      rows = [border_row(polity.id)]

      assert {:ok, stats} = Atlas.replace_borders("cliopatria", rows)
      assert stats.purged == 0
      assert stats.inserted == 1
      assert Atlas.count_borders() == 1
    end

    test "idempotence: replaying the same rows for the same source yields the same final state" do
      {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      rows = [border_row(polity.id), border_row(polity.id, %{from_year: 200, to_year: 300})]

      assert {:ok, _stats} = Atlas.replace_borders("cliopatria", rows)
      assert Atlas.count_borders() == 2

      assert {:ok, stats} = Atlas.replace_borders("cliopatria", rows)
      assert stats.purged == 2
      assert stats.inserted == 2
      assert Atlas.count_borders() == 2
    end

    test "edge case: rows of another source are never purged" do
      {:ok, cliopatria_polity} = Atlas.upsert_polity(%{name: "Rome", source: "cliopatria"})
      {:ok, hbm_polity} = Atlas.upsert_polity(%{name: "Rome", source: "historical_basemaps"})

      {:ok, _} =
        Atlas.replace_borders("historical_basemaps", [
          border_row(hbm_polity.id, %{source: "historical_basemaps"})
        ])

      {:ok, _} = Atlas.replace_borders("cliopatria", [border_row(cliopatria_polity.id)])

      assert Atlas.count_borders() == 2
      assert {:ok, _} = Atlas.replace_borders("cliopatria", [])
      assert Atlas.count_borders() == 1
    end

    test "edge case: an empty Enumerable purges and inserts nothing" do
      assert {:ok, stats} = Atlas.replace_borders("cliopatria", [])
      assert stats == %{purged: 0, total: 0, repaired: 0, inserted: 0, rejected_empty: 0}
    end

    test "edge case: accepts a lazy Stream, not just a list" do
      {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      rows = Stream.map([1], fn _ -> border_row(polity.id) end)

      assert {:ok, stats} = Atlas.replace_borders("cliopatria", rows)
      assert stats.inserted == 1
    end

    test "limit case: more rows than the internal batch size are all inserted (chunked)" do
      {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      rows = for i <- 1..450, do: border_row(polity.id, %{from_year: i, to_year: i})

      assert {:ok, stats} = Atlas.replace_borders("cliopatria", rows)
      assert stats.inserted == 450
      assert Atlas.count_borders() == 450
    end
  end

  describe "count_borders/0 and count_polities/0" do
    test "count queries reflect the current row counts" do
      assert Atlas.count_borders() == 0
      assert Atlas.count_polities() == 0

      {:ok, polity} = Atlas.upsert_polity(%{name: "Roman Empire", source: "cliopatria"})
      {:ok, _} = Atlas.replace_borders("cliopatria", [border_row(polity.id)])

      assert Atlas.count_polities() == 1
      assert Atlas.count_borders() == 1
    end
  end

  describe "indexes and constraints" do
    test "qid has a unique constraint" do
      qid = hd(unique_qids(1))
      event_fixture(qid: qid)

      assert {:error, changeset} =
               %Event{}
               |> Event.changeset(event_attrs(qid: qid))
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
      qid: hd(unique_qids(1)),
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
