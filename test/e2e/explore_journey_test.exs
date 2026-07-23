defmodule AmanogawaWeb.E2E.ExploreJourneyTest do
  @moduledoc """
  The critical journey (issue #029's main deliverable, issue #018): load
  `/`, wait for the map, select an event, verify the URL and the panel,
  reload the shared URL and verify the restored state, close with Escape.

  Selection goes through the test-only hook witness
  (`AmanogawaWeb.E2EHelpers.select_event/2`) rather than a canvas click:
  this journey's own assertions are about the LiveView/URL/panel contract
  (`AmanogawaWeb.ExploreLive`, `AmanogawaWeb.Components.EventPanel`), which
  a real marker click would only reach *through* WebGL hit-testing that is
  itself unrelated to what is being asserted here (and unassertable, the
  canvas point d'attention). The hover and relation-lines scenarios
  (`test/e2e/explore_map_test.exs`) exercise the real canvas interaction.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Wallaby.Query

  @marathon_qid "Q31900"
  @marathon_lng 23.9750
  @marathon_lat 38.1128

  setup do
    event =
      AtlasFixtures.event_fixture(%{
        qid: @marathon_qid,
        label_fr: "Bataille de Marathon",
        label_en: "Battle of Marathon",
        begin_year: -490,
        begin_precision: 9,
        geom: %Geo.Point{coordinates: {@marathon_lng, @marathon_lat}, srid: 4326},
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
        extract_fr: "Bataille livrée en -490 entre Athènes et l'empire perse.",
        extract_attribution: %{
          "article_url" => "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          "license" => "CC BY-SA 4.0"
        },
        sitelink_count: 200
      })

    %{event: event}
  end

  feature "loads the map, selects an event, shares and restores the URL, closes with Escape",
          %{session: session} do
    session
    |> visit("/")
    |> wait_for_map_ready()
    |> assert_has(Query.css("#event-panel", count: 0))
    |> select_event(@marathon_qid)
    |> assert_has(Query.css("#event-panel", text: "Bataille de Marathon"))

    assert current_url(session) =~ "sel=#{@marathon_qid}"

    session
    |> assert_has(Query.css("#event-panel", text: "Bataille livrée en -490"))
    |> assert_has(Query.css("#event-panel", text: "CC BY-SA 4.0"))

    wiki_link =
      find(
        session,
        Query.css("#event-panel a[href='https://fr.wikipedia.org/wiki/Bataille_de_Marathon']")
      )

    assert Wallaby.Element.attr(wiki_link, "target") == "_blank"
    assert Wallaby.Element.attr(wiki_link, "rel") == "noopener noreferrer"

    shared_url = current_url(session)

    session
    |> visit(shared_url)
    |> wait_for_map_ready()
    |> assert_has(Query.css("#event-panel", text: "Bataille de Marathon"))

    session
    |> send_keys([:escape])
    |> assert_has(Query.css("#event-panel", count: 0))

    refute current_url(session) =~ "sel="
  end
end
