defmodule AmanogawaWeb.E2E.ExploreTimelineTest do
  @moduledoc """
  Frise (timeline strip) scenarios added to issue #029 after F04's review
  (`docs/features/003-carte-interactive/006-tests-e2e-parcours-critique.md`):
  the review found these are exactly what would have caught F04's three
  major findings (the histogram 422 at load, the silent rejection at the
  right edge, tick crowding), none of which `Phoenix.LiveViewTest` or a
  unit test can see, since they are about the *rendered* SVG (`d3`, not
  MapLibre/WebGL, so fully DOM-assertable, unlike `explore_map_test.exs`).

  Every scenario reads geometry off the real DOM
  (`AmanogawaWeb.E2EHelpers.axis_tick_positions/1`,
  `histogram_bar_heights/1`, `svg_geometry/2`), simulates drags with
  synthetic Pointer Events (`drag_element/3`, the standard way to drive a
  hand-rolled Pointer Events widget from a headless browser), and
  synchronizes on `#map`'s `data-events-fetch-count` (`wait_for_events_
  fetch_count/2`) as the one reliable proxy for "the server round trip
  this drag triggered has landed and the map/frise/legend all re-rendered
  from it": `TimelineHook`'s own `set_time_window` handler
  (`assets/js/hooks/timeline.js`) and `MapHook`'s (`map_hook.js`) both
  react to the exact same push, so the map refetching is downstream proof
  the frise's own state settled too.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Wallaby.Query

  # A minimum window width in years the axis leaves at each end of the
  # 1400px viewport (`config/test.exs`'s `--window-size=1400,1000`) that
  # counts as "the axis spans (close enough to) the whole strip":
  # `TimelineHook`'s own `MARGIN.left`/`MARGIN.right` are 16px each, a few
  # pixels of tolerance absorbs tick-label centering/anti-aliasing without
  # weakening what the assertion actually proves.
  @axis_edge_tolerance_px 10

  setup do
    for year <- [-50_000, -3_000, 1789, 1945, 2020] do
      AtlasFixtures.event_fixture(%{begin_year: year, begin_precision: 9})
    end

    :ok
  end

  feature "renders a non-empty histogram spanning the full domain on initial load",
          %{session: session} do
    session
    |> visit("/")
    |> wait_for_map_ready()
    |> wait_for_histogram_ready()

    assert Enum.any?(histogram_bar_heights(session), &(&1 > 0)),
           "expected at least one histogram bucket with a non-zero count at load"

    assert_axis_spans_full_domain(session)
  end

  feature "dragging the window body translates it (URL patched, width preserved, map/frise/legend synced)",
          %{session: session} do
    session
    |> visit("/?from=-5000&to=2000")
    |> wait_for_map_ready()
    |> wait_for_histogram_ready()

    %{width: width_before} = svg_geometry(session, ".timeline-window-body")
    fetch_count_before = events_fetch_count(session)

    session
    |> drag_element(".timeline-window-body", -200)
    |> wait_for_events_fetch_count(fetch_count_before + 1)

    %{width: width_after} = svg_geometry(session, ".timeline-window-body")
    assert_in_delta width_after, width_before, 1.0

    refute current_url(session) =~ "from=-5000&to=2000"
  end

  feature "dragging the right handle past the domain edge patches the URL to the domain bound, no silent rejection",
          %{session: session} do
    domain_max_year = Date.utc_today().year

    session
    |> visit("/?from=-5000&to=2000")
    |> wait_for_map_ready()
    |> wait_for_histogram_ready()

    fetch_count_before = events_fetch_count(session)

    session
    |> drag_element(".timeline-window-handle-to", 5_000)
    |> wait_for_events_fetch_count(fetch_count_before + 1)

    assert current_url(session) =~ "to=#{domain_max_year}"
  end

  feature "a narrow window (1789-1815) highlights narrowly while the axis stays full domain",
          %{session: session} do
    session
    |> visit("/?from=1789&to=1815")
    |> wait_for_map_ready()
    |> wait_for_histogram_ready()

    %{width: window_width} = svg_geometry(session, ".timeline-window-body")
    assert window_width < 15.0, "expected a 26-year window on a 315000-year domain to be a sliver"

    assert has_text?(session, Query.css("#time-legend"), "1789")
    assert has_text?(session, Query.css("#time-legend"), "1815")

    assert_axis_spans_full_domain(session)
  end

  defp assert_axis_spans_full_domain(session) do
    positions = axis_tick_positions(session)

    assert positions != [], "expected the axis to render at least one tick"
    assert Enum.all?(positions, &is_number/1), "expected every tick to expose a numeric position"

    assert Enum.min(positions) <= @axis_edge_tolerance_px
    assert Enum.max(positions) >= 1400 - @axis_edge_tolerance_px
  end
end
