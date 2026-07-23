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
  """
  use AmanogawaWeb, :live_view

  alias Amanogawa.Atlas
  alias AmanogawaWeb.Components.EventPanel
  alias AmanogawaWeb.Components.TimeLegend
  alias AmanogawaWeb.Params.ExploreParams
  alias AmanogawaWeb.RateLimit

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

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Carte du monde"))
     |> assign(:peer_ip, peer_ip(socket))
     |> assign(:from, nil)
     |> assign(:to, nil)
     |> assign(:z, nil)
     |> assign(:lat, nil)
     |> assign(:lng, nil)
     |> assign(:selected_qid, nil)
     |> assign(:selected_event, nil)}
  end

  # Captured once at mount, not re-read on every event: `get_connect_info/2`
  # only returns data during the (single) connected mount, `nil` on the
  # static, disconnected render. A `nil` peer (no connect_info at all, e.g.
  # `mount/3` called directly as a plain function, as the "no DB in
  # mount" test below does) is never throttled by
  # `selection_rate_limited?/1`: there is no real client to protect
  # against.
  #
  # Deliberately the raw socket peer, not corrected for a reverse proxy
  # the way `AmanogawaWeb.Plugs.RateLimit`'s HTTP-side quota is (issue
  # security-review #4's `RemoteIp` plug runs on the endpoint's HTTP
  # pipeline, which a LiveView websocket connection never goes through):
  # good enough to bound abuse from a single client, not meant to be an
  # exact client identity behind arbitrary infrastructure.
  #
  # `get_connect_info/2` itself raises when `socket.private[:connect_info]`
  # is entirely absent (a socket that never went through the LiveView
  # mount lifecycle at all, as opposed to one that went through it but
  # simply lacks a `:peer_data` key): guarded against explicitly here
  # rather than left to crash, since `mount/3` is called directly, as a
  # bare struct, by its own "no DB access" test below.
  defp peer_ip(%{private: private} = socket) do
    if Map.has_key?(private, :connect_info) do
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _other -> nil
      end
    else
      nil
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    state = ExploreParams.parse(params)
    previous = current_view(socket)

    socket =
      socket
      |> assign(from: state.from, to: state.to)
      |> assign(z: state.z, lat: state.lat, lng: state.lng)
      |> apply_selection(state.selected_qid)
      |> push_view_state(state, previous)

    {:noreply, socket}
  end

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

  def handle_event("deselect_event", _params, socket) do
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- data-i18n-* carries the labels the hover card
      (`assets/js/map/hover_card.js`) renders into its DOM, translated
      server-side (security review, i18n finding): the hook reads them off
      this container instead of hardcoding French text in JS. --%>
      <div
        id="map"
        phx-hook="MapHook"
        phx-update="ignore"
        class="absolute inset-0"
        data-i18n-text-label={gettext("Texte")}
      >
      </div>
      <EventPanel.event_panel :if={@selected_event} event={@selected_event} />
      <:timeline>
        <%!-- phx-update="ignore": LiveView never touches this subtree, d3
        owns it entirely (`.claude/rules/liveview.md`). `data-from`/
        `data-to` seed the hook's initial window; `set_time_window`
        (pushed by `push_view_state/3` below, the same event the map hook
        already consumes) keeps it in sync with the LiveView-owned state
        afterwards. --%>
        <div class="relative h-full w-full">
          <div
            id="timeline-hook"
            phx-hook="TimelineHook"
            phx-update="ignore"
            class="h-full w-full"
            data-from={@from}
            data-to={@to}
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

  defp load_selection(socket, nil), do: assign(socket, selected_qid: nil, selected_event: nil)

  defp load_selection(socket, qid) do
    case Atlas.get_event_by_qid(qid) do
      nil -> assign(socket, selected_qid: nil, selected_event: nil)
      event -> assign(socket, selected_qid: qid, selected_event: event)
    end
  end

  defp patch_path(socket, changes) do
    state = %{
      from: socket.assigns.from,
      to: socket.assigns.to,
      selected_qid: socket.assigns.selected_qid,
      z: socket.assigns.z,
      lat: socket.assigns.lat,
      lng: socket.assigns.lng
    }

    updated = Enum.reduce(changes, state, fn {key, value}, acc -> Map.put(acc, key, value) end)

    case ExploreParams.to_query(updated) do
      empty when empty == %{} -> ~p"/"
      query -> "/?" <> URI.encode_query(query)
    end
  end

  defp selection_rate_limited?(%{assigns: %{peer_ip: nil}}), do: false

  defp selection_rate_limited?(%{assigns: %{peer_ip: peer_ip}}) do
    {limit, scale_ms} = selection_rate_limit_quota()

    case RateLimit.hit({:explore_select, peer_ip}, scale_ms, limit) do
      {:allow, _count} -> false
      {:deny, _retry_after_ms} -> true
    end
  end

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
