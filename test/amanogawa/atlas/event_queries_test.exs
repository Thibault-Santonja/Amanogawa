defmodule Amanogawa.Atlas.EventQueriesTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.TimeScale
  alias AmanogawaWeb.Params.EventsQuery

  @world %{min_lon: -180.0, min_lat: -90.0, max_lon: 180.0, max_lat: 90.0}

  describe "list_events_geojson/1 integration" do
    test "an event on each side of the antimeridian is found by a bbox crossing it" do
      east =
        event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {179.0, 10.0}, srid: 4326})

      west =
        event_fixture(qid: "Q2", geom: %Geo.Point{coordinates: {-179.0, 10.0}, srid: 4326})

      opts = full_range_opts(envelopes: antimeridian_envelopes())

      result = Atlas.list_events_geojson(opts)
      qids = Enum.map(result["features"], & &1["properties"]["qid"])

      assert Enum.sort(qids) == Enum.sort([east.qid, west.qid])
    end

    test "an event outside the bbox is excluded" do
      event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326})

      far_away_bbox = [%{min_lon: 100.0, min_lat: 80.0, max_lon: 110.0, max_lat: 85.0}]
      result = Atlas.list_events_geojson(full_range_opts(envelopes: far_away_bbox))

      assert result["features"] == []
    end

    test "an event without geom is excluded" do
      event_fixture(qid: "Q1", geom: nil)

      result = Atlas.list_events_geojson(full_range_opts())

      assert result["features"] == []
    end

    test "label falls back to English when French is absent" do
      event_fixture(qid: "Q1", label_fr: nil, label_en: "English only")

      result = Atlas.list_events_geojson(full_range_opts())

      assert [%{"properties" => %{"label" => "English only"}}] = result["features"]
    end

    test "an event outside the time window is excluded" do
      event_fixture(qid: "Q1", begin_year: -1000)

      result = Atlas.list_events_geojson(full_range_opts(from: 0, to: 100))

      assert result["features"] == []
    end

    test "an ongoing event (end_year set) is found by a window overlapping its span" do
      event_fixture(qid: "Q1", begin_year: -100, end_year: 100, end_precision: 9)

      result = Atlas.list_events_geojson(full_range_opts(from: 50, to: 60))

      assert [%{"properties" => %{"qid" => "Q1"}}] = result["features"]
    end

    test "features expose exactly qid, label, year, precision and importance" do
      event_fixture(
        qid: "Q1",
        label_fr: "Nom francais",
        begin_year: 1789,
        begin_precision: 9,
        sitelink_count: 12
      )

      result = Atlas.list_events_geojson(full_range_opts())

      assert [feature] = result["features"]
      assert feature["type"] == "Feature"

      assert Map.keys(feature["properties"]) |> Enum.sort() ==
               ~w(importance label precision qid year)

      assert feature["properties"] == %{
               "qid" => "Q1",
               "label" => "Nom francais",
               "year" => 1789,
               "precision" => 9,
               "importance" => 12
             }
    end

    test "results are ranked by importance descending, tied by qid ascending" do
      event_fixture(qid: "Q3", sitelink_count: 5)
      event_fixture(qid: "Q1", sitelink_count: 10)
      event_fixture(qid: "Q2", sitelink_count: 10)

      result = Atlas.list_events_geojson(full_range_opts())
      qids = Enum.map(result["features"], & &1["properties"]["qid"])

      assert qids == ["Q1", "Q2", "Q3"]
    end

    test "limit caps the number of features returned" do
      for i <- 1..5, do: event_fixture(qid: "Q#{i}")

      result = Atlas.list_events_geojson(full_range_opts(limit: 2))

      assert length(result["features"]) == 2
    end
  end

  describe "list_events_geojson/1 properties" do
    setup do
      events =
        for lon <- [-170, -90, -10, 10, 90, 170],
            lat <- [-80, -30, 0, 30, 80],
            {year, sitelink} <- [{-2500, 3}, {-100, 50}, {500, 1}, {1800, 900}] do
          event_fixture(
            qid: "Q#{System.unique_integer([:positive])}",
            geom: %Geo.Point{coordinates: {lon * 1.0, lat * 1.0}, srid: 4326},
            begin_year: year,
            begin_precision: 9,
            sitelink_count: sitelink
          )
        end

      %{events: events}
    end

    property "every feature is within the bbox, its year within the window, and count <= limit" do
      check all bbox_string <- valid_bbox_string(),
                from <- integer(-3000..Date.utc_today().year),
                to <- integer(from..Date.utc_today().year),
                limit <- integer(1..50),
                max_runs: 30 do
        {:ok, envelopes} = EventsQuery.parse_bbox(bbox_string)
        opts = %{envelopes: envelopes, from: from, to: to, limit: limit}

        result = Atlas.list_events_geojson(opts)
        features = result["features"]

        assert length(features) <= limit

        for feature <- features do
          [lon, lat] = feature["geometry"]["coordinates"]
          year = feature["properties"]["year"]

          assert within_any_envelope?(lon, lat, envelopes)
          assert year >= from and year <= to
        end
      end
    end

    property "features are always ranked by importance descending" do
      check all bbox_string <- valid_bbox_string(),
                max_runs: 20 do
        {:ok, envelopes} = EventsQuery.parse_bbox(bbox_string)
        opts = %{envelopes: envelopes, from: -3000, to: Date.utc_today().year, limit: 500}

        importances =
          opts
          |> Atlas.list_events_geojson()
          |> Map.fetch!("features")
          |> Enum.map(& &1["properties"]["importance"])

        assert importances == Enum.sort(importances, :desc)
      end
    end
  end

  describe "list_links/1 properties" do
    @link_types ~w(part_of follows cause effect significant)a

    property "every feature returned by list_event_links_geojson/1 has two positions, world-bound coordinates, and a valid link_type" do
      check all relation_count <- integer(0..8),
                types <- list_of(member_of(@link_types), length: relation_count),
                max_runs: 20 do
        center = event_fixture(qid: unique_qid())

        Enum.each(types, fn type ->
          target =
            event_fixture(
              qid: unique_qid(),
              geom: %Geo.Point{coordinates: {random_lon(), random_lat()}, srid: 4326}
            )

          event_link_fixture(source_id: center.id, target_id: target.id, type: type)
        end)

        assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson(center.qid)
        assert length(features) == relation_count

        for feature <- features do
          assert feature["geometry"]["type"] == "LineString"
          assert [_first, _second] = coordinates = feature["geometry"]["coordinates"]

          for [lon, lat] <- coordinates do
            assert lon >= -180.0 and lon <= 180.0
            assert lat >= -90.0 and lat <= 90.0
          end

          assert feature["properties"]["link_type"] in Enum.map(@link_types, &Atom.to_string/1)
        end
      end
    end

    defp random_lon, do: :rand.uniform() * 360 - 180
    defp random_lat, do: :rand.uniform() * 180 - 90
    defp unique_qid, do: "Q#{System.unique_integer([:positive])}"
  end

  describe "list_links/1 limit and order" do
    test "outgoing relations beyond the per-direction cap are dropped, keeping the most important by target sitelink_count, then qid" do
      center = event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326})

      for i <- 1..205 do
        target =
          event_fixture(
            qid: "Q#{1000 + i}",
            geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
            sitelink_count: i
          )

        event_link_fixture(source_id: center.id, target_id: target.id, type: :part_of)
      end

      assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson("Q1")
      assert length(features) == 200

      target_qids = Enum.map(features, & &1["properties"]["target_qid"])
      # The 5 least important targets (sitelink_count 1..5) are dropped;
      # the rest come back ranked by sitelink_count descending.
      expected_qids = for i <- 205..6//-1, do: "Q#{1000 + i}"

      assert target_qids == expected_qids
    end

    test "incoming relations are capped independently of outgoing ones" do
      center = event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326})

      for i <- 1..205 do
        source =
          event_fixture(
            qid: "Q#{2000 + i}",
            geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
            sitelink_count: i
          )

        event_link_fixture(source_id: source.id, target_id: center.id, type: :follows)
      end

      assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson("Q1")
      assert length(features) == 200
      assert Enum.all?(features, &(&1["properties"]["direction"] == "incoming"))
    end

    test "targets tied on sitelink_count are tie-broken by qid ascending" do
      center = event_fixture(qid: "Q1", geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326})

      higher_qid =
        event_fixture(
          qid: "Q30",
          geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
          sitelink_count: 10
        )

      lower_qid =
        event_fixture(
          qid: "Q20",
          geom: %Geo.Point{coordinates: {0.0, 0.0}, srid: 4326},
          sitelink_count: 10
        )

      event_link_fixture(source_id: center.id, target_id: higher_qid.id, type: :part_of)
      event_link_fixture(source_id: center.id, target_id: lower_qid.id, type: :part_of)

      assert {:ok, %{"features" => features}} = Atlas.list_event_links_geojson("Q1")
      assert Enum.map(features, & &1["properties"]["target_qid"]) == ["Q20", "Q30"]
    end
  end

  describe "histogram_counts/1" do
    setup do
      %{scale: TimeScale.default()}
    end

    test "happy path: counts events per bucket, edges aligned on TimeScale.year/2", %{
      scale: scale
    } do
      event_fixture(begin_year: -100)
      event_fixture(begin_year: -100)
      event_fixture(begin_year: 500)
      event_fixture(begin_year: 1500)

      counts =
        Atlas.EventQueries.histogram_counts(%{from: -1000, to: 2000, buckets: 3, scale: scale})

      assert Enum.sum(Map.values(counts)) == 4
    end

    test "edge case: an empty window yields no counts at all" do
      event_fixture(begin_year: 2999)

      counts =
        Atlas.EventQueries.histogram_counts(%{
          from: -1000,
          to: 2000,
          buckets: 10,
          scale: TimeScale.default()
        })

      assert counts == %{}
    end

    test "edge case: an event exactly on the upper bound lands in the last bucket, not overflow",
         %{scale: scale} do
      event_fixture(begin_year: 2000)

      counts = Atlas.EventQueries.histogram_counts(%{from: 0, to: 2000, buckets: 4, scale: scale})

      assert counts == %{4 => 1}
    end

    test "edge case: an event exactly on the lower bound lands in the first bucket", %{
      scale: scale
    } do
      event_fixture(begin_year: 0)

      counts = Atlas.EventQueries.histogram_counts(%{from: 0, to: 2000, buckets: 4, scale: scale})

      assert counts == %{1 => 1}
    end

    test "limit case: buckets=1 returns a single global count", %{scale: scale} do
      for year <- [-500, 0, 500, 1000], do: event_fixture(begin_year: year)

      counts =
        Atlas.EventQueries.histogram_counts(%{from: -1000, to: 2000, buckets: 1, scale: scale})

      assert counts == %{1 => 4}
    end

    property "conservation: the sum of counts equals the number of events within the window" do
      scale = TimeScale.default()

      check all from <- integer(-3000..1000),
                to <- integer((from + 100)..2000),
                buckets <- integer(1..50),
                years <- list_of(integer(-3000..2000), max_length: 15),
                max_runs: 15 do
        # Each iteration reuses the same sandboxed connection (the sandbox
        # only rolls back once, at the end of the whole test, not between
        # `check all` iterations): the corpus is reset here so `expected`
        # below reflects exactly this iteration's `years`, not a growing
        # accumulation across every prior run.
        Repo.delete_all(Amanogawa.Atlas.Event)
        for year <- years, do: event_fixture(begin_year: year)

        expected = Enum.count(years, &(&1 >= from and &1 <= to))

        counts =
          Atlas.EventQueries.histogram_counts(%{
            from: from,
            to: to,
            buckets: buckets,
            scale: scale
          })

        assert Enum.sum(Map.values(counts)) == expected
      end
    end
  end

  describe "histogram_counts/1 SQL/edges cohesion (issue #020, F04 quality finding m5)" do
    test "the SQL width_bucket assignment matches the announced integer bucket edges" do
      scale = TimeScale.default()
      opts = %{from: -50_000, to: 2000, buckets: 20, scale: scale}

      years = [-50_000, -20_000, -10_000, -5_000, -489, 0, 500, 1000, 1789, 1969, 2000]
      for year <- years, do: event_fixture(begin_year: year)

      sql_counts = Atlas.EventQueries.histogram_counts(opts)
      edges = Atlas.EventQueries.bucket_edges(opts)

      expected_counts =
        years
        |> Enum.map(&edge_bucket(edges, opts.buckets, &1))
        |> Enum.frequencies()

      assert sql_counts == expected_counts
    end

    test "an event exactly on an interior integer edge lands in the bucket that starts there" do
      opts = %{from: 0, to: 2000, buckets: 4, scale: TimeScale.default()}

      # The second interior edge (the exact integer year the response
      # announces as bucket 3's `from`): the announced contract says a
      # `begin_year` equal to it belongs to bucket 3, not bucket 2.
      edge_year = opts |> Atlas.EventQueries.bucket_edges() |> Enum.at(2)
      event_fixture(begin_year: edge_year)

      assert Atlas.EventQueries.histogram_counts(opts) == %{3 => 1}
    end

    test "bucket_edges/1 announces from/to exactly, as strictly increasing integers" do
      opts = %{from: -50_000, to: 2000, buckets: 20, scale: TimeScale.default()}

      edges = Atlas.EventQueries.bucket_edges(opts)

      assert length(edges) == 21
      assert hd(edges) == -50_000
      assert List.last(edges) == 2000
      assert edges == Enum.sort(edges)
      assert edges == Enum.uniq(edges)
      assert Enum.all?(edges, &is_integer/1)
    end

    # The announced bucket of `year` against the integer `edges` contract:
    # bucket `k` covers `[edge(k-1), edge(k))`, the last bucket closed on
    # both ends. Mirrors in Elixir what the SQL
    # `width_bucket(begin_year, interior_edges) + 1` computes.
    defp edge_bucket(edges, buckets, year) do
      interior = edges |> Enum.drop(1) |> Enum.drop(-1)
      bucket = Enum.count(interior, &(&1 <= year)) + 1
      min(bucket, buckets)
    end
  end

  defp within_any_envelope?(lon, lat, envelopes) do
    Enum.any?(envelopes, fn envelope ->
      lon >= envelope.min_lon and lon <= envelope.max_lon and
        lat >= envelope.min_lat and lat <= envelope.max_lat
    end)
  end

  defp valid_bbox_string do
    gen all min_lon <- integer(-180..180),
            max_lon <- integer(-180..180),
            lat_a <- integer(-90..89),
            lat_b <- integer((lat_a + 1)..90) do
      "#{min_lon}.0,#{lat_a}.0,#{max_lon}.0,#{lat_b}.0"
    end
  end

  defp antimeridian_envelopes do
    {:ok, envelopes} = EventsQuery.parse_bbox("170,-10,-170,10")
    envelopes
  end

  defp full_range_opts(overrides \\ []) do
    Map.merge(
      %{envelopes: [@world], from: -13_800_000_000, to: Date.utc_today().year, limit: 500},
      Map.new(overrides)
    )
  end
end
