defmodule AmanogawaWeb.ExploreLive do
  @moduledoc """
  Explore: the full-screen world map with the timeline strip below, and the
  central owner of shareable state (issue #018): time window, map view,
  and selection, synchronized with the URL (ADR 0005).

  Replaces the minimal `HomeLive` from #005: one LiveView per page
  (`.claude/rules/liveview.md`).

  `mount/3` assigns defaults only, no database access. `handle_params/3` is
  the sole point that turns the URL into assigns, including the event
  lookup for a selected `sel` (loaded there, never in `mount/3`, the
  LiveView iron law). Every `handle_event` validates its payload, then
  `push_patch`es the URL; it never mutates state directly, so
  `handle_params/3` stays the single source of truth and the browser's
  back/forward buttons replay state for free.

  The event panel itself (`AmanogawaWeb.Components.EventPanel`, issue
  #016) is fed from the `selected_event` assign loaded here; the hover
  card and the relation lines traced on the map (issue #017) are owned
  entirely by the JS hook, driven by the `event_selected`/
  `event_deselected` events pushed below.

  ## Time-window domain and rendering model (F04 decisions D1/D2)

  D1: the time window lives on ONE domain, `Amanogawa.Atlas.TimeScale.
  default/0`'s `[-300_000, current UTC year]`, shared by the URL parsing
  and validation (`AmanogawaWeb.Params.ExploreParams`), the histogram
  bounds (`AmanogawaWeb.Params.HistogramQuery`), and the client hooks:
  this LiveView renders it as `data-domain-min`/`data-domain-max` on the
  timeline hook element, the only channel through which JS learns the
  bounds. D2: the timeline itself is a static full-domain frise (axis
  ticks and histogram cover the whole domain, fetched once); the window
  assigns here only drive the brush highlight and the map's temporal
  filter, never an axis or histogram reload.
  """
  use AmanogawaWeb, :live_view

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.TimeScale
  alias Amanogawa.Contributions
  alias AmanogawaWeb.ClientIp
  alias AmanogawaWeb.Components.EventPanel
  alias AmanogawaWeb.Components.TimeLegend
  alias AmanogawaWeb.Params.ExploreParams
  alias AmanogawaWeb.RateLimit
  alias AmanogawaWeb.TimelineI18n

  # Generous, dedicated quota for `select_event` (issue security-review
  # #6: it is the only `handle_event` here that ends up loading from the
  # database, through the `handle_params/3` that `push_patch` below
  # triggers): independent from the public JSON API's own quota
  # (`AmanogawaWeb.Plugs.RateLimit`, `config :amanogawa, AmanogawaWeb.
  # RateLimit`), since 60 clicks/minute from one visitor is unremarkable
  # here but would be a very different signal on the JSON API. Overridable
  # via `config :amanogawa, #{inspect(__MODULE__)}` (see
  # `selection_rate_limit_quota/0`), which is what lets tests reach the
  # "throttled" path with a handful of hits instead of sixty.
  @default_selection_rate_limit 60
  @default_selection_rate_limit_scale_ms :timer.minutes(1)

  # The `propose_field` query param's closed allowlist (issue #036):
  # mirrors, but never calls, `AmanogawaWeb.Components.EventPanel`'s own
  # list and `Amanogawa.Contributions.Override.field_names/0` (kept in
  # sync by hand across the web/domain boundary, same reasoning as
  # `Amanogawa.Atlas.OverridableField`'s own moduledoc).
  @correction_fields ~w(label_fr label_en begin_date end_date position link)

  @impl true
  def mount(_params, _session, socket) do
    # The single server-side time-window domain (F04 design decision D1,
    # `Amanogawa.Atlas.TimeScale.default/0`), transmitted to the client
    # hooks through `data-domain-min`/`data-domain-max` below: the JS side
    # never hardcodes these bounds, it reads them off the DOM. Pure
    # arithmetic, no database access (LiveView iron law).
    %TimeScale{min_year: domain_min, max_year: domain_max} = TimeScale.default()

    {:ok,
     socket
     |> assign(:page_title, gettext("Carte du monde"))
     |> assign(:peer_ip, ClientIp.peer_ip(socket))
     |> assign(:domain_min, domain_min)
     |> assign(:domain_max, domain_max)
     |> assign(:axis_templates, TimelineI18n.axis_templates())
     |> assign(:from, nil)
     |> assign(:to, nil)
     |> assign(:z, nil)
     |> assign(:lat, nil)
     |> assign(:lng, nil)
     |> assign(:selected_qid, nil)
     |> assign(:selected_event, nil)
     |> assign(:contribution_summary, nil)
     |> assign(:proposal_mode, nil)
     |> assign(:view_query, %{})
     |> assign(:proposal_close_path, "/")
     |> assign(:expose_e2e_test_api, Application.get_env(:amanogawa, :expose_e2e_test_api, false))}
  end

  # The peer IP is captured once at mount (`AmanogawaWeb.ClientIp.peer_ip/1`),
  # not re-read on every event: `get_connect_info/2` only returns data
  # during the (single) connected mount, `nil` on the static, disconnected
  # render. A `nil` (no connect_info at all, e.g. `mount/3` called
  # directly as a plain function, as the "no DB in mount" test below
  # does) is never throttled by `selection_rate_limited?/1`: there is no
  # real client to protect against. Behind a reverse proxy the helper
  # resolves the forwarded client (same trusted proxy list as the HTTP
  # `RemoteIp` plug) instead of the proxy's own address, which would
  # otherwise be one shared throttle bucket for every visitor.

  @impl true
  def handle_params(params, _url, socket) do
    state = ExploreParams.parse(params)
    previous = current_view(socket)

    socket =
      socket
      |> assign(from: state.from, to: state.to)
      |> assign(z: state.z, lat: state.lat, lng: state.lng)
      |> apply_selection(state.selected_qid)

    # Depends on the RESOLVED selection (`apply_selection/2` above), not
    # `state.selected_qid`: a correction on an unknown/dangling `sel`
    # never opens the form (issue #036). Also depends on
    # `@current_scope.user`: never trust a client-supplied query param
    # (`.claude/rules/liveview.md`) to open a form that assumes an
    # authenticated author. An anonymous visitor pasting or guessing this
    # URL directly sees the map exactly as if the param were absent, the
    # panel's own link to `AmanogawaWeb.ProposalController` being the
    # sanctioned way in (F08 overview's "droit affiché, pas un privilège
    # caché" is about visibility of the ENTRY POINT, not about the form
    # ever rendering for a signed-out visitor).
    socket =
      assign(
        socket,
        :proposal_mode,
        parse_proposal_mode(
          params,
          socket.assigns.selected_qid,
          socket.assigns.current_scope.user
        )
      )

    # Derived from the assigns just written, recomputed on every URL
    # change: the panel's correction links and the proposal form's close
    # path both preserve the current window/camera (see `view_query/1`).
    socket =
      socket
      |> assign(:view_query, view_query(socket))
      |> assign(:proposal_close_path, form_close_path(socket))

    {:noreply, push_view_state(socket, state, previous)}
  end

  # `propose_field` opens `AmanogawaWeb.Live.ProposalFormComponent` in
  # correction mode for the currently selected event (issue #036): the
  # query string is the single source of truth, so the form survives a
  # refresh (`.claude/rules/liveview.md`). `propose_new_event` opens it in
  # creation mode, independent of any selection.
  defp parse_proposal_mode(_params, _selected_qid, nil), do: nil

  defp parse_proposal_mode(%{"propose_field" => field}, selected_qid, _user)
       when not is_nil(selected_qid) and field in @correction_fields do
    {:correction, field}
  end

  defp parse_proposal_mode(%{"propose_new_event" => "1"}, _selected_qid, _user), do: :new_event
  defp parse_proposal_mode(_params, _selected_qid, _user), do: nil

  # Snapshot of the assigns `push_view_state/3` below decides against,
  # taken *before* `handle_params/3` overwrites them with the freshly
  # parsed `state`: this is what lets a patch that only changes, say, the
  # selection (`select_event`) skip re-pushing `set_time_window`/`set_view`
  # for a window/camera that did not actually move (issue security-review
  # #2: every `handle_params/3` run used to unconditionally re-push both,
  # triggering a redundant `/api/events` refetch in the hook on every
  # selection change).
  defp current_view(socket) do
    %{
      from: socket.assigns.from,
      to: socket.assigns.to,
      z: socket.assigns.z,
      lat: socket.assigns.lat,
      lng: socket.assigns.lng
    }
  end

  # Pushed on every `handle_params/3` run, since every run is itself the
  # result of a URL change (initial load, `push_patch`, or browser
  # back/forward): the map hook's anti-loop guard (marking programmatic
  # moves) is what keeps a `map_moved`-triggered patch from re-triggering
  # itself through the `set_view` pushed back here. `set_time_window` and
  # `set_view` are each only pushed when their value actually changed from
  # `previous` (see `current_view/1`): a pure selection or browser
  # back/forward replaying the same window/camera must not cause the hook
  # to redundantly refetch events or re-animate the camera.
  #
  # `event_selected`/`event_deselected` carry `socket.assigns.selected_qid`
  # (the *resolved* selection, set by `apply_selection/2` above), not
  # `state.selected_qid`: a `sel` naming an unknown event resolves to no
  # selection, and the hook must be told that, not the dangling qid from
  # the URL.
  defp push_view_state(socket, state, previous) do
    if connected?(socket) do
      selected_qid = socket.assigns.selected_qid

      socket
      |> maybe_push_time_window(state, previous)
      |> maybe_push_view(state, previous)
      |> push_event(
        if(selected_qid, do: "event_selected", else: "event_deselected"),
        %{qid: selected_qid}
      )
    else
      socket
    end
  end

  defp maybe_push_time_window(socket, state, previous) do
    if {state.from, state.to} == {previous.from, previous.to} do
      socket
    else
      push_event(socket, "set_time_window", %{from: state.from, to: state.to})
    end
  end

  defp maybe_push_view(socket, state, previous) do
    if {state.z, state.lat, state.lng} == {previous.z, previous.lat, previous.lng} do
      socket
    else
      push_event(socket, "set_view", %{z: state.z, lat: state.lat, lng: state.lng})
    end
  end

  @impl true
  def handle_event("select_event", %{"qid" => qid}, socket) do
    cond do
      not ExploreParams.valid_qid?(qid) ->
        {:noreply, socket}

      # Over quota: the event is dropped silently, no crash and no patch
      # (issue security-review #6), exactly like an invalid payload above.
      selection_rate_limited?(socket) ->
        {:noreply, socket}

      true ->
        {:noreply, push_patch(socket, to: patch_path(socket, selected_qid: qid))}
    end
  end

  def handle_event("select_event", _params, socket), do: {:noreply, socket}

  # Deselecting also drops an open CORRECTION form (issue #036: a
  # correction targets the selected event, so `propose_field` without a
  # `sel` would be an orphan query param that `parse_proposal_mode/3`
  # ignores but every later patch would keep dragging along); a
  # `propose_new_event` form is selection-independent and survives.
  def handle_event("deselect_event", _params, socket) do
    socket =
      case socket.assigns.proposal_mode do
        {:correction, _field} -> assign(socket, :proposal_mode, nil)
        _other -> socket
      end

    {:noreply, push_patch(socket, to: patch_path(socket, selected_qid: nil))}
  end

  def handle_event("map_moved", %{"z" => z, "lat" => lat, "lng" => lng}, socket) do
    if ExploreParams.valid_view?(z, lat, lng) do
      {:noreply,
       push_patch(socket, to: patch_path(socket, z: z, lat: lat, lng: lng), replace: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("map_moved", _params, socket), do: {:noreply, socket}

  # Client -> server intent (issue #021), pushed by `TimelineHook` after
  # its 150ms drag debounce (`assets/js/hooks/timeline.js`'s `pushWindow`).
  # Deliberately named differently from `set_time_window`, the server ->
  # client push consumed by both hooks (`maybe_push_time_window/3` below):
  # the two directions used to share one name, which is exactly the
  # ambiguity `.claude/rules/liveview.md`'s "explicit verb" convention
  # exists to prevent. `replace: true` (mirroring `map_moved`'s own patch
  # below): a drag debounces at 150ms but can still patch several times
  # per gesture, and a `push_patch` per tick would otherwise flood the
  # browser history with intermediate windows nobody would ever want to
  # navigate back through individually.
  def handle_event("select_time_window", %{"from" => from, "to" => to}, socket) do
    if ExploreParams.valid_window?(from, to) do
      {:noreply, push_patch(socket, to: patch_path(socket, from: from, to: to), replace: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_time_window", _params, socket), do: {:noreply, socket}

  # Position picking (issue #036): `MapHook`'s `pushEvent` always targets
  # the LiveView, never a component directly (hooks are not
  # component-scoped in the DOM), so this forwards the picked coordinate
  # to `AmanogawaWeb.Live.ProposalFormComponent` with `send_update/2`.
  # Bounded to the whole world server-side (`.claude/rules/security.md`):
  # never trusts the client's `{lng, lat}` payload as-is. Guarded on
  # `@proposal_mode` so a stray/late event with no open form is a no-op.
  def handle_event("position_picked", %{"lng" => lng, "lat" => lat}, socket) do
    if socket.assigns.proposal_mode && valid_lng_lat?(lng, lat) do
      send_update(AmanogawaWeb.Live.ProposalFormComponent,
        id: "proposal-form",
        picked_position: %{lng: lng / 1, lat: lat / 1}
      )
    end

    {:noreply, socket}
  end

  def handle_event("position_picked", _params, socket), do: {:noreply, socket}

  defp valid_lng_lat?(lng, lat) when is_number(lng) and is_number(lat) do
    lng >= -180 and lng <= 180 and lat >= -90 and lat <= 90
  end

  defp valid_lng_lat?(_lng, _lat), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <%!-- data-i18n-* carries the labels the hover card
      (`assets/js/map/hover_card.js`) renders into its DOM, translated
      server-side (security review, i18n finding): the hook reads them off
      this container instead of hardcoding French text in JS. --%>
      <%!-- Sized with h-full/w-full rather than absolute/inset-0: MapLibre's
      own stylesheet (imported unlayered) sets `position: relative` on
      `.maplibregl-map`, and unlayered rules always beat Tailwind's
      `@layer utilities`, which silently collapsed the absolute box to a
      zero height (caught by the e2e suite, issue #029). --%>
      <div
        id="map"
        phx-hook="MapHook"
        phx-update="ignore"
        class="h-full w-full"
        data-i18n-text-label={gettext("Texte")}
        data-i18n-webgl-fallback={
          gettext("Carte interactive indisponible : ce navigateur ne fournit pas WebGL.")
        }
        data-e2e-test-api={@expose_e2e_test_api && "true"}
      >
      </div>

      <%!-- Discrete, always-visible entry (issue #036, anti-dark-patterns:
      no aggressive call-to-action): a signed-in visitor patches straight
      into the form below, an anonymous one is routed through
      `AmanogawaWeb.ProposalController`'s `/connexion` return-to flow. --%>
      <div class="pointer-events-none absolute inset-x-0 top-14 flex justify-end p-2">
        <.link
          :if={@current_scope.user}
          patch={new_event_patch(@view_query)}
          class="pointer-events-auto rounded-md bg-surface/90 px-3 py-1.5 text-sm text-text shadow hover:bg-surface"
        >
          {gettext("Proposer un événement")}
        </.link>
        <.link
          :if={!@current_scope.user}
          href={new_event_href(@view_query)}
          class="pointer-events-auto rounded-md bg-surface/90 px-3 py-1.5 text-sm text-text shadow hover:bg-surface"
        >
          {gettext("Proposer un événement")}
        </.link>
      </div>

      <EventPanel.event_panel
        :if={@selected_event}
        event={@selected_event}
        current_scope={@current_scope}
        contribution_summary={@contribution_summary}
        view_query={@view_query}
      />
      <.live_component
        :if={@proposal_mode}
        module={AmanogawaWeb.Live.ProposalFormComponent}
        id="proposal-form"
        mode={@proposal_mode}
        event={@selected_event}
        current_scope={@current_scope}
        peer_ip={peer_ip_string(@peer_ip)}
        close_path={@proposal_close_path}
      />
      <:timeline>
        <%!-- phx-update="ignore": LiveView never touches this subtree, d3
        owns it entirely (`.claude/rules/liveview.md`). `data-from`/
        `data-to` seed the hook's initial window; `set_time_window`
        (pushed by `push_view_state/3` below, the same event the map hook
        already consumes) keeps it in sync with the LiveView-owned state
        afterwards. `data-domain-min`/`data-domain-max` carry the single
        server-side time-window domain (F04 decision D1,
        `Amanogawa.Atlas.TimeScale.default/0`); the `data-i18n-*`
        attributes carry the translated axis-label templates and handle
        ARIA labels (`AmanogawaWeb.TimelineI18n`, same pattern as the
        hover card's labels on #map above). --%>
        <div class="relative h-full w-full">
          <div
            id="timeline-hook"
            phx-hook="TimelineHook"
            phx-update="ignore"
            class="h-full w-full"
            data-from={@from}
            data-to={@to}
            data-domain-min={@domain_min}
            data-domain-max={@domain_max}
            data-i18n-ka-bp={@axis_templates.ka_bp}
            data-i18n-century={@axis_templates.century}
            data-i18n-bce={@axis_templates.bce}
            data-i18n-window-start={TimelineI18n.window_start_label()}
            data-i18n-window-end={TimelineI18n.window_end_label()}
          >
          </div>
          <%!-- Outside the hook's `phx-update="ignore"` subtree (issue #022):
          LiveView re-renders this on every `from`/`to` assign change, unlike
          the hook's own SVG, which d3 owns entirely. --%>
          <TimeLegend.time_legend from={@from} to={@to} />
        </div>
      </:timeline>
    </Layouts.app>
    """
  end

  # Only queries Atlas when the selection actually changes: a pure
  # `map_moved`/`set_time_window` patch re-runs `handle_params/3` without
  # touching the database.
  defp apply_selection(socket, selected_qid) do
    if selected_qid == socket.assigns.selected_qid do
      socket
    else
      load_selection(socket, selected_qid)
    end
  end

  defp load_selection(socket, nil) do
    assign(socket, selected_qid: nil, selected_event: nil, contribution_summary: nil)
  end

  defp load_selection(socket, qid) do
    case Atlas.get_event_by_qid(qid) do
      nil ->
        assign(socket, selected_qid: nil, selected_event: nil, contribution_summary: nil)

      event ->
        assign(socket,
          selected_qid: qid,
          selected_event: event,
          # Computed HERE, once per actual selection change (issue #038):
          # never inside `AmanogawaWeb.Components.EventPanel` itself,
          # whose function component body would otherwise rerun this
          # query on every unrelated re-render of the page while the
          # panel stays open (`apply_selection/2` above already guards
          # against re-querying Atlas on a pure map/timeline patch, the
          # same discipline applies here).
          contribution_summary: Contributions.event_contribution_summary(qid)
        )
    end
  end

  # `ExploreParams.to_query/1` only ever serializes `from`/`to`/`sel`/`z`/
  # `lat`/`lng` (its own concern is the time window and camera, not the
  # proposal form): `propose_field`/`propose_new_event` are appended here
  # instead, straight from `@proposal_mode`, so every patch this LiveView
  # itself issues (`map_moved`, `select_time_window`, `select_event`,
  # `deselect_event`) preserves an open proposal form by construction. A
  # PRODUCTION bug this fixes, found by issue #039's own E2E journeys, not
  # merely a test artifact: MapLibre settling the camera after a selection
  # (or a contributor nudging the map/timeline while drafting a
  # justification) used to `push_patch` a URL with no `propose_field` at
  # all, silently closing the form out from under them mid-edit.
  defp patch_path(socket, changes) do
    updated =
      Enum.reduce(changes, explore_state(socket), fn {key, value}, acc ->
        Map.put(acc, key, value)
      end)

    updated
    |> ExploreParams.to_query()
    |> Map.merge(proposal_mode_query(socket))
    |> query_to_path()
  end

  defp explore_state(socket) do
    %{
      from: socket.assigns.from,
      to: socket.assigns.to,
      selected_qid: socket.assigns.selected_qid,
      z: socket.assigns.z,
      lat: socket.assigns.lat,
      lng: socket.assigns.lng
    }
  end

  defp query_to_path(query) when query == %{}, do: ~p"/"
  defp query_to_path(query), do: "/?" <> URI.encode_query(query)

  # The current window/camera/selection as query params, WITHOUT any
  # proposal param (quality review m-finding, same production concern as
  # `patch_path/2`'s own comment above): handed to `AmanogawaWeb.
  # Components.EventPanel` (correction links) and `AmanogawaWeb.Live.
  # ProposalFormComponent` (its own close path), so opening or closing
  # the proposal form never resets the time window or the camera.
  defp view_query(socket) do
    socket |> explore_state() |> ExploreParams.to_query()
  end

  defp form_close_path(socket) do
    socket |> view_query() |> query_to_path()
  end

  # Same view preservation for the "Proposer un événement" entry points
  # (header links): the signed-in patch and the anonymous `/proposer`
  # round trip both keep the current window/camera.
  defp new_event_patch(view_query) do
    "/?" <> URI.encode_query(Map.put(view_query, "propose_new_event", "1"))
  end

  defp new_event_href(view_query) do
    "/proposer?" <> URI.encode_query(Map.put(view_query, "new_event", "1"))
  end

  defp proposal_mode_query(%{assigns: %{proposal_mode: {:correction, field}}}) do
    %{"propose_field" => field}
  end

  defp proposal_mode_query(%{assigns: %{proposal_mode: :new_event}}) do
    %{"propose_new_event" => "1"}
  end

  defp proposal_mode_query(_socket), do: %{}

  defp selection_rate_limited?(%{assigns: %{peer_ip: nil}}), do: false

  defp selection_rate_limited?(%{assigns: %{peer_ip: peer_ip}}) do
    {limit, scale_ms} = selection_rate_limit_quota()

    case RateLimit.hit({:explore_select, peer_ip}, scale_ms, limit) do
      {:allow, _count} -> false
      {:deny, _retry_after_ms} -> true
    end
  end

  defp peer_ip_string(nil), do: nil
  defp peer_ip_string(ip), do: ip |> :inet.ntoa() |> to_string()

  defp selection_rate_limit_quota do
    config = Application.get_env(:amanogawa, __MODULE__, [])

    limit = Keyword.get(config, :selection_rate_limit, @default_selection_rate_limit)

    scale_ms =
      Keyword.get(
        config,
        :selection_rate_limit_scale_ms,
        @default_selection_rate_limit_scale_ms
      )

    {limit, scale_ms}
  end
end
