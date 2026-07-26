defmodule AmanogawaWeb.E2EHelpers do
  @moduledoc """
  Shared plumbing for the E2E suite (issue #029): waiting on the DOM
  readiness signals `assets/js/hooks/map_hook.js`/`timeline.js` render
  (`data-events-loaded`, `data-histogram-loaded`, `data-events-fetch-
  count`), driving the test-only `window.__amanogawaE2E__` witness, and
  simulating Pointer Events drags on the timeline's SVG handles/body.

  Not a `Wallaby.Feature`/case template itself (`AmanogawaWeb.FeatureCase`
  is): plain functions imported where needed, so a test file only pulls in
  what it actually drives (map helpers, timeline helpers, or both).
  """

  import ExUnit.Assertions
  import Swoosh.TestAssertions
  import Wallaby.Browser

  alias Wallaby.Query
  alias Wallaby.Session
  alias Wallaby.WebdriverClient

  @doc """
  Waits for the map hook's events layer to have rendered at least once
  (`data-events-loaded="true"` on `#map`, set by `MapHook#setEventsData`):
  the WebGL canvas itself is not assertable, this is the DOM proxy for "a
  click/hover on a marker will now hit something".
  """
  @spec wait_for_map_ready(Session.t()) :: Session.t()
  def wait_for_map_ready(session) do
    # Fail fast, with a distinct message, when MapHook degraded because no
    # WebGL context could be created (`data-map-degraded`, see
    # `renderWebglFallback`): the generic "events never loaded" timeout
    # below would otherwise hide the real cause.
    degraded =
      session
      |> Wallaby.Browser.attr(Query.css("#map", visible: :any), "data-map-degraded")

    if degraded == "true" do
      raise "MapHook degraded: no WebGL context could be created in this browser " <>
              "(data-map-degraded=true); the events layer will never load. " <>
              "Check the chrome flags in config/test.exs."
    end

    assert_has(session, Query.css("#map[data-events-loaded='true']", visible: :any))

    # Webdriver's `displayed` check needs a nonzero box: surface the real
    # geometry when the layout collapses instead of failing later with an
    # opaque "0 visible elements" on a child query.
    Wallaby.Browser.execute_script(
      session,
      "var r = document.querySelector('#map').getBoundingClientRect();" <>
        "var shell = document.querySelector('main#map-zone');" <>
        "var sr = shell ? shell.getBoundingClientRect() : {width: -1, height: -1};" <>
        "return [r.width, r.height, window.innerWidth, window.innerHeight," <>
        " document.styleSheets.length, sr.height," <>
        " CSS.supports('height', '100dvh'), getComputedStyle(document.body).height];",
      fn [w, h, iw, ih, sheets, shell_h, dvh, body_h] ->
        if h < 10 or w < 10 do
          raise "#map collapsed to #{w}x#{h} (viewport #{iw}x#{ih}, " <>
                  "stylesheets #{sheets}, map-zone height #{shell_h}, " <>
                  "dvh supported #{dvh}, body height #{body_h}): " <>
                  "the layout gives the map zero size in this browser."
        end
      end
    )
  rescue
    error in [Wallaby.QueryError, Wallaby.ExpectationNotMetError] ->
      # Diagnostic of last resort: what page is the browser actually on?
      source = Wallaby.Browser.page_source(session)

      reraise RuntimeError.exception(
                Exception.message(error) <>
                  "\n\nPage source (first 3000 bytes):\n" <>
                  String.slice(source, 0, 3000)
              ),
              __STACKTRACE__
  end

  @doc """
  Waits until MapLibre reports itself fully loaded (`Map#loaded()` through
  the test witness's `mapLoaded`): `wait_for_map_ready/1`'s
  `data-events-loaded` proves the events reached the GeoJSON source, but
  the engine still processes and renders the tiles a few frames later, and
  until then a real pointer event over a marker hit-tests against nothing.
  Required before any scenario drives the canvas with a real cursor
  (hover); scenarios that only talk to the LiveView contract do not need
  it.
  """
  @spec wait_for_map_rendered(Session.t(), non_neg_integer()) :: Session.t()
  def wait_for_map_rendered(session, attempts_left \\ 50) do
    {:ok, loaded} =
      WebdriverClient.execute_script(session, "return window.__amanogawaE2E__.mapLoaded()", [])

    cond do
      loaded == true ->
        session

      attempts_left > 0 ->
        Process.sleep(100)
        wait_for_map_rendered(session, attempts_left - 1)

      true ->
        raise "MapLibre never reached loaded() (tiles still processing or rendering)"
    end
  end

  @doc """
  The current `data-events-fetch-count` on `#map`, as an integer: the
  number of times `MapHook#setEventsData` has run since the page loaded.
  """
  @spec events_fetch_count(Session.t()) :: integer()
  def events_fetch_count(session) do
    session
    |> attr(Query.css("#map"), "data-events-fetch-count")
    |> String.to_integer()
  end

  @doc """
  Waits until `#map`'s `data-events-fetch-count` reaches at least
  `expected_count`: used after an action expected to trigger a fresh
  events fetch (a theme change reloading the style, `MapHook#onStyleLoad`)
  to confirm a *new* fetch landed, not merely that one happened at some
  point in the past.
  """
  @spec wait_for_events_fetch_count(Session.t(), integer(), non_neg_integer()) :: Session.t()
  def wait_for_events_fetch_count(session, expected_count, attempts_left \\ 120) do
    # Polls for >= rather than an exact attribute match: on slow CI
    # runners an extra legitimate fetch (resize settle, moveend) can land
    # between the read of the baseline and the awaited one, jumping the
    # counter past the expected value and making an equality selector
    # unsatisfiable forever.
    count = events_fetch_count(session)

    cond do
      count >= expected_count ->
        session

      attempts_left > 0 ->
        Process.sleep(250)
        wait_for_events_fetch_count(session, expected_count, attempts_left - 1)

      true ->
        raise "data-events-fetch-count stuck at #{count}, expected at least #{expected_count}"
    end
  end

  @doc """
  Waits until `#map`'s `data-links-count` equals exactly `expected_count`
  (`MapHook#setLinksData`/`#clearEventLinks`): the DOM proxy for "the
  relation lines for the current selection are drawn" (a non-zero count)
  or "cleared" (`0`), since the line layer itself is a WebGL source.
  """
  @spec wait_for_links_count(Session.t(), non_neg_integer()) :: Session.t()
  def wait_for_links_count(session, expected_count) do
    assert_has(session, Query.css("#map[data-links-count='#{expected_count}']"))
  end

  @doc """
  Waits for the timeline hook's histogram to have rendered at least once
  (`data-histogram-loaded="true"` on `#timeline-hook`, set by
  `TimelineHook#fetchHistogram`).
  """
  @spec wait_for_histogram_ready(Session.t()) :: Session.t()
  def wait_for_histogram_ready(session) do
    assert_has(session, Query.css("#timeline-hook[data-histogram-loaded='true']"))
  end

  @doc """
  Waits for the map hook's borders layer to have rendered at least once
  (`data-borders-loaded="true"` on `#map`, set by `MapHook#setBordersData`,
  issue #025): the WebGL canvas itself is not assertable, this is the DOM
  proxy for "the `GET /api/borders` fetch for the current reference year
  landed".
  """
  @spec wait_for_borders_ready(Session.t()) :: Session.t()
  def wait_for_borders_ready(session) do
    assert_has(session, Query.css("#map[data-borders-loaded='true']", visible: :any))
  end

  @doc """
  Waits until `#map`'s `data-borders-count` equals exactly `expected_count`
  (`MapHook#setBordersData`, issue #025): the DOM proxy for "the borders
  layer for the current reference year holds this many features",
  mirroring `wait_for_links_count/2`.
  """
  @spec wait_for_borders_count(Session.t(), non_neg_integer()) :: Session.t()
  def wait_for_borders_count(session, expected_count) do
    assert_has(session, Query.css("#map[data-borders-count='#{expected_count}']"))
  end

  @doc """
  Selects `qid` through the test-only hook witness
  (`window.__amanogawaE2E__.selectEvent`, `assets/js/hooks/map_hook.js`,
  only wired when `config :amanogawa, :expose_e2e_test_api` is `true`):
  sends the exact same `select_event` intent a real marker click does,
  without depending on WebGL canvas hit-testing for scenarios that only
  care about the LiveView/URL/panel contract.
  """
  @spec select_event(Session.t(), String.t()) :: Session.t()
  def select_event(session, qid) do
    execute_script(session, "window.__amanogawaE2E__.selectEvent(arguments[0])", [qid])
  end

  @doc """
  Deselects the current event through the same test-only witness as
  `select_event/2`.
  """
  @spec deselect_event(Session.t()) :: Session.t()
  def deselect_event(session) do
    execute_script(session, "window.__amanogawaE2E__.deselectEvent()")
  end

  @doc """
  The complete passwordless sign-in journey (issue #032, factored out of
  `test/e2e/auth_journey_test.exs`'s own private helper so issue #039's
  contributor and reviewer journeys reuse it too, per that issue's own
  point d'attention): from wherever `session` currently is, opens
  `/connexion`, requests a magic link for `email`, captures its URL from
  the shared Swoosh test mailbox (the caller's own `setup` must have
  called `AmanogawaWeb.FeatureCase.share_swoosh_mailbox/0` first, exactly
  as `test/e2e/auth_journey_test.exs` already does), visits it, and clicks
  the real confirm button. Returns `session`, now signed in as `email`.
  """
  @spec sign_in_via_magic_link(Session.t(), String.t()) :: Session.t()
  def sign_in_via_magic_link(session, email) do
    session
    |> visit("/connexion")
    |> assert_has(Query.css("#login-form"))
    |> fill_in(Query.css("input[name='login[email]']"), with: email)
    |> click(Query.css("#login-form button", text: "Recevoir un lien de connexion"))
    |> assert_has(Query.css("#magic-link-sent"))

    assert_email_sent(fn sent_email ->
      assert sent_email.to == [{"", email}]

      [url] = Regex.run(~r{https?://\S+/connexion/\S+}, sent_email.text_body)
      send(self(), {:captured_magic_link_url, String.trim(url)})
      true
    end)

    assert_receive {:captured_magic_link_url, magic_link_url}

    session
    |> visit(magic_link_url)
    |> click(Query.css("button", text: "Confirmer la connexion"))
    |> assert_has(Query.css("#topbar", text: email))
  end

  @doc """
  Picks `{lng, lat}` through the test-only hook witness
  (`window.__amanogawaE2E__.pickPosition`, `assets/js/hooks/map_hook.js`,
  issue #039): sends the exact same `position_picked` intent a real map
  click does while `AmanogawaWeb.Live.ProposalFormComponent`'s "Choisir
  sur la carte" is active, without depending on WebGL canvas hit-testing
  for a specific pixel (the contributor journey only cares about the
  LiveView/form contract, not the map's own rendering, already covered
  by the map/hover/relation-lines scenarios).
  """
  @spec pick_position(Session.t(), float(), float()) :: Session.t()
  def pick_position(session, lng, lat) do
    execute_script(session, "window.__amanogawaE2E__.pickPosition(arguments[0], arguments[1])", [
      lng,
      lat
    ])
  end

  @doc """
  Clicks the FIRST element matched by `css_selector` through a genuine DOM
  `.click()` call (`execute_script/2`) rather than Wallaby's own native
  WebDriver click: still a trusted `click` event, so `phoenix_html`'s
  patch-link listener fires exactly as it would for a real pointer click,
  but sidesteps WebDriver's own element-coordinate computation (which can
  intermittently miss a link inside a just-toggled `<details>`, issue
  #039's own contributor/reviewer journeys). Prefer `Wallaby.Browser.
  click/2` for anything this suite ALSO wants to prove is reachable by a
  real pointer (buttons, the map canvas); reach for this only for a patch
  link whose click TARGET, not its physical clickability, is what the
  scenario is actually about.
  """
  @spec click_via_js(Session.t(), String.t()) :: Session.t()
  def click_via_js(session, css_selector) do
    execute_script(session, "document.querySelector(arguments[0]).click()", [css_selector])
  end

  @doc """
  Retries `fun` (a `session -> session` Wallaby action, e.g. `&fill_in(&1,
  query, with: "x")` or `&click(&1, query)`) up to `attempts` times when the
  DOM node it targets goes stale BETWEEN Wallaby's own find and act
  (`Wallaby.StaleReferenceError`, issue #039's own contributor/reviewer
  journeys): a background LiveView patch (the map/timeline hooks push
  fairly often, `map_moved`/`select_time_window`) can replace a node the
  exact moment a real click/fill_in reaches for it, a real-browser race no
  `Phoenix.LiveViewTest` process ever has to contend with. A short sleep
  between attempts gives the in-flight patch time to settle before the
  retry.
  """
  @spec retry_stale(Session.t(), (Session.t() -> Session.t()), pos_integer()) :: Session.t()
  def retry_stale(session, fun, attempts \\ 3)

  def retry_stale(session, fun, attempts) when attempts > 1 do
    fun.(session)
  rescue
    Wallaby.StaleReferenceError ->
      Process.sleep(200)
      retry_stale(session, fun, attempts - 1)
  end

  def retry_stale(session, fun, _attempts), do: fun.(session)

  @doc """
  Emulates `prefers-color-scheme: dark` for the whole session through
  chromedriver's Chromium CDP passthrough (`POST .../chromium/send_command`
  running `Emulation.setEmulatedMedia`): the one reliable, version-stable
  way to flip the media query a real browser reports, as opposed to a
  Chrome command-line flag (`--force-dark-mode` forces *content* darkening
  heuristics, it does not reliably flip `prefers-color-scheme` for a page
  that already ships its own dark theme, which this app does,
  `assets/css/app.css`). Dispatches a genuine `change` event to any
  already-registered `matchMedia` listener (`MapHook#onSchemeChange`
  included), so it works whether called before or after `visit/2`.

  Requires no extra dependency: `Req` is the project's mandated HTTP
  client (`CLAUDE.md`), and chromedriver's session base URL is already on
  `session.session_url` (`base_url <> "session/\#{id}"`,
  `Wallaby.Chrome.start_session/1`).
  """
  @spec emulate_dark_mode(Session.t()) :: Session.t()
  def emulate_dark_mode(session), do: emulate_color_scheme(session, "dark")

  @doc """
  Emulates an arbitrary `prefers-color-scheme` value (same CDP passthrough
  as `emulate_dark_mode/1`). The dark-mode scenario emulates `"light"`
  BEFORE loading the page: headless Chrome inherits the host OS theme, so
  without pinning the baseline the later switch to dark would be a no-op
  (no `change` event, no style reload) whenever the host itself runs dark.
  """
  @spec emulate_color_scheme(Session.t(), String.t()) :: Session.t()
  def emulate_color_scheme(session, scheme) do
    {:ok, _response} =
      Req.post(session.session_url <> "/chromium/send_command",
        json: %{
          cmd: "Emulation.setEmulatedMedia",
          params: %{features: [%{name: "prefers-color-scheme", value: scheme}]}
        }
      )

    session
  end

  @doc """
  The computed value of a CSS custom property on `<html>` (issue #029's
  dark-mode scenario reads `--palette-surface`, `assets/css/app.css`, to
  confirm the app's own light/dark theming followed the emulated
  preference: a DOM/CSS-only proxy, never the WebGL canvas).
  """
  @spec computed_custom_property(Session.t(), String.t()) :: String.t()
  def computed_custom_property(session, name) do
    script =
      "return getComputedStyle(document.documentElement).getPropertyValue(arguments[0]).trim()"

    # `Wallaby.WebdriverClient.execute_script/3` (unlike `Wallaby.Browser.
    # execute_script/2..4`, which always returns its `parent` for
    # pipeability) is the one that actually returns the script's value.
    {:ok, value} = WebdriverClient.execute_script(session, script, [name])
    value
  end

  @doc """
  Simulates a full Pointer Events drag gesture (`pointerdown`, two
  `pointermove`s, `pointerup`, all with `isPrimary: true`/`button: 0`, the
  guard `TimelineHook#beginDrag` requires) on the element matched by
  `css_selector`, from its current center by `delta_x_px` horizontally:
  the standard, portable way to drive a hand-rolled Pointer Events widget
  (the timeline's SVG window body/handles, `assets/js/hooks/timeline.js`)
  from a headless browser, since neither Wallaby's `click/2` nor the W3C
  Actions API model a "press, move, move, release" gesture on an arbitrary
  element directly.

  `pointerId` is fixed at `1`: only one drag gesture is ever simulated at
  a time in this suite, and the hook itself only tracks a single
  `this.drag` regardless.
  """
  @spec drag_element(Session.t(), String.t(), integer()) :: Session.t()
  def drag_element(session, css_selector, delta_x_px) do
    script = """
    const [selector, deltaX] = arguments
    const el = document.querySelector(selector)
    const rect = el.getBoundingClientRect()
    const startX = rect.left + rect.width / 2
    const startY = rect.top + rect.height / 2
    const endX = startX + deltaX
    const base = {
      bubbles: true,
      cancelable: true,
      pointerId: 1,
      pointerType: "mouse",
      isPrimary: true,
      button: 0,
      clientY: startY
    }

    el.dispatchEvent(new PointerEvent("pointerdown", {...base, clientX: startX}))
    window.dispatchEvent(
      new PointerEvent("pointermove", {...base, clientX: startX + deltaX / 2})
    )
    window.dispatchEvent(new PointerEvent("pointermove", {...base, clientX: endX}))
    window.dispatchEvent(new PointerEvent("pointerup", {...base, clientX: endX}))
    """

    execute_script(session, script, [css_selector, delta_x_px])
  end

  @doc """
  The `x`/`width` (floats) of the SVG element matched by `css_selector`,
  read as attributes: `TimelineHook#renderWindow`/`#positionHandle` set
  these directly (no CSS transform), so they are the ground truth for "how
  wide is the window highlight" / "where is this handle" assertions.
  """
  @spec svg_geometry(Session.t(), String.t()) :: %{x: float(), width: float()}
  def svg_geometry(session, css_selector) do
    script = """
    const el = document.querySelector(arguments[0])
    return {x: el.getAttribute("x"), width: el.getAttribute("width")}
    """

    {:ok, %{"x" => x, "width" => width}} =
      WebdriverClient.execute_script(session, script, [css_selector])

    %{x: parse_float!(x), width: parse_float!(width)}
  end

  @doc """
  The x-translation (float, pixels) of every rendered `.timeline-axis
  .tick` group, in DOM order: `TimelineHook#renderAxis` graduates the axis
  over the FULL domain regardless of the current window (F04 decision D2),
  so this is what the E2E suite reads to confirm "the axis still spans the
  whole strip" independently of how narrow the current window's own
  highlight is.
  """
  @spec axis_tick_positions(Session.t()) :: [float()]
  def axis_tick_positions(session) do
    script = """
    return Array.from(document.querySelectorAll(".timeline-axis .tick")).map(tick => {
      const match = /translate\\(([-\\d.]+)/.exec(tick.getAttribute("transform"))
      return match ? parseFloat(match[1]) : null
    })
    """

    {:ok, positions} = WebdriverClient.execute_script(session, script, [])
    positions
  end

  @doc """
  The rendered `height` (floats, pixels) of every `.timeline-histogram
  rect` bar: `TimelineHook#renderHistogram` draws one bar per bucket
  regardless of its count, so bars *existing* does not prove the
  histogram is non-empty (F04's own "422 histogramme au chargement"
  finding was exactly this: the strip rendered, every bar at zero). This
  is what the E2E suite reads to confirm at least one bucket actually
  holds events.
  """
  @spec histogram_bar_heights(Session.t()) :: [float()]
  def histogram_bar_heights(session) do
    script = """
    return Array.from(document.querySelectorAll(".timeline-histogram rect"))
      .map(rect => parseFloat(rect.getAttribute("height")))
    """

    {:ok, heights} = WebdriverClient.execute_script(session, script, [])
    heights
  end

  defp parse_float!(value) do
    {float, ""} = Float.parse(value)
    float
  end
end
