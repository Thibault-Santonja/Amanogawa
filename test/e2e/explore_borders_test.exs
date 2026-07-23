defmodule AmanogawaWeb.E2E.ExploreBordersTest do
  @moduledoc """
  The historical borders layer's critical path (issue #025): a border
  fixture active at the default reference year renders on load
  (`data-borders-loaded`/`data-borders-count` on `#map`, the WebGL canvas
  itself being unassertable, `AmanogawaWeb.E2EHelpers`'s established
  pattern for every other MapLibre-rendered layer), and changing the time
  window updates the reference year (the window's upper bound, F05 design)
  and re-fetches accordingly.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Wallaby.Query

  # Covers up to the border data domain's own upper bound (2024,
  # `AmanogawaWeb.Params.BorderQuery`): the default page load's reference
  # year is the *event* domain's upper bound (the current UTC year,
  # `AmanogawaWeb.Params.ExploreParams`'s own default), clamped server-side
  # to 2024, so a border active through 2024 is the one guaranteed to still
  # be showing regardless of which year `mix test.e2e` happens to run in.
  @roman_from_year -100
  @roman_to_year 2024

  setup do
    polity = AtlasFixtures.polity_fixture(name: "Roman Empire", source: "cliopatria")

    AtlasFixtures.border_fixture(
      polity_id: polity.id,
      source: "cliopatria",
      from_year: @roman_from_year,
      to_year: @roman_to_year
    )

    :ok
  end

  feature "renders the borders layer on load and refetches when the time window's upper bound changes",
          %{session: session} do
    session
    |> visit("/")
    |> wait_for_map_ready()
    |> wait_for_borders_ready()
    |> wait_for_borders_count(1)

    # A window entirely before the fixture's `from_year` moves the
    # reference year (the window's upper bound) outside the border's
    # active span: the borders layer must re-fetch and settle on an empty
    # FeatureCollection, proving the fetch is keyed off the reference year
    # actually changing, not merely off page load.
    session
    |> visit("/?from=-3000&to=-2500")
    |> wait_for_map_ready()
    |> wait_for_borders_ready()
    |> wait_for_borders_count(0)
  end

  feature "credits Cliopatria and historical-basemaps in the map attribution", %{session: session} do
    session
    |> visit("/")
    |> wait_for_map_ready()
    |> assert_has(Query.css(".maplibregl-ctrl-attrib", text: "Cliopatria"))
    |> assert_has(Query.css(".maplibregl-ctrl-attrib", text: "historical-basemaps"))
  end
end
