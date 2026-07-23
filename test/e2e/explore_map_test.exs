defmodule AmanogawaWeb.E2E.ExploreMapTest do
  @moduledoc """
  Map interaction scenarios that genuinely need a real browser hovering
  and rendering the WebGL canvas (issue #029): the hover card's
  micro-delay and dismissal, the relation lines drawn at selection and
  cleared at deselection (including two successive selections replacing,
  not accumulating, the lines), and dark mode.

  Every scenario centers the camera on the fixture event's own coordinates
  (`z`/`lat`/`lng` query params, `AmanogawaWeb.Params.ExploreParams`) at a
  high enough zoom that its marker renders at the canvas's center: hovering
  `#map canvas` (`Wallaby.Browser.hover/2` moves the pointer to an
  element's center) then lands on the marker without needing pixel-level
  projection math in the test itself.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Wallaby.Query

  @center_lng 2.3522
  @center_lat 48.8566
  @center_zoom 10

  setup do
    source =
      AtlasFixtures.event_fixture(%{
        label_fr: "Prise de la Bastille",
        begin_year: 1789,
        begin_precision: 11,
        geom: %Geo.Point{coordinates: {@center_lng, @center_lat}, srid: 4326},
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Prise_de_la_Bastille",
        extract_fr: "Événement fondateur de la Révolution française.",
        extract_attribution: %{
          "article_url" => "https://fr.wikipedia.org/wiki/Prise_de_la_Bastille",
          "license" => "CC BY-SA 4.0"
        },
        sitelink_count: 300
      })

    target_1 =
      AtlasFixtures.event_fixture(%{geom: %Geo.Point{coordinates: {2.0, 49.0}, srid: 4326}})

    target_2a =
      AtlasFixtures.event_fixture(%{geom: %Geo.Point{coordinates: {1.0, 48.0}, srid: 4326}})

    target_2b =
      AtlasFixtures.event_fixture(%{geom: %Geo.Point{coordinates: {3.0, 47.0}, srid: 4326}})

    second_source =
      AtlasFixtures.event_fixture(%{geom: %Geo.Point{coordinates: {2.5, 48.5}, srid: 4326}})

    AtlasFixtures.event_link_fixture(source_id: source.id, target_id: target_1.id, type: :cause)

    AtlasFixtures.event_link_fixture(
      source_id: second_source.id,
      target_id: target_2a.id,
      type: :part_of
    )

    AtlasFixtures.event_link_fixture(
      source_id: second_source.id,
      target_id: target_2b.id,
      type: :effect
    )

    %{source: source, second_source: second_source}
  end

  defp centered_path do
    "/?z=#{@center_zoom}&lat=#{@center_lat}&lng=#{@center_lng}"
  end

  feature "shows the hover card after the micro-delay and hides it when the cursor leaves",
          %{source: source, session: session} do
    session
    |> visit(centered_path())
    |> wait_for_map_ready()
    |> hover(Query.css("#map canvas"))
    |> assert_has(Query.css("[role='tooltip'][aria-hidden='false']", text: source.label_fr))

    session
    |> hover(Query.css("header#topbar"))
    |> assert_has(Query.css("[role='tooltip'][aria-hidden='false']", count: 0))
  end

  feature "draws the relation lines at selection and clears them at deselection",
          %{source: source, session: session} do
    session
    |> visit(centered_path())
    |> wait_for_map_ready()
    |> select_event(source.qid)
    |> wait_for_links_count(1)

    session
    |> deselect_event()
    |> wait_for_links_count(0)
  end

  feature "replaces, rather than accumulates, the relation lines across two successive selections",
          %{source: source, second_source: second_source, session: session} do
    session
    |> visit(centered_path())
    |> wait_for_map_ready()
    |> select_event(source.qid)
    |> wait_for_links_count(1)
    |> select_event(second_source.qid)
    |> wait_for_links_count(2)
  end

  feature "switches the map to the dark style on prefers-color-scheme: dark, keeping events displayed",
          %{session: session} do
    session
    |> visit(centered_path())
    |> wait_for_map_ready()

    light_surface = computed_custom_property(session, "--palette-surface")
    fetch_count_before_switch = events_fetch_count(session)

    session
    |> emulate_dark_mode()
    |> wait_for_events_fetch_count(fetch_count_before_switch + 1)

    dark_surface = computed_custom_property(session, "--palette-surface")

    assert dark_surface != light_surface
    assert dark_surface != ""
  end
end
