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
  alias AmanogawaWeb.Params.ExploreParams

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Carte du monde"))
     |> assign(:from, nil)
     |> assign(:to, nil)
     |> assign(:kinds, [])
     |> assign(:z, nil)
     |> assign(:lat, nil)
     |> assign(:lng, nil)
     |> assign(:selected_qid, nil)
     |> assign(:selected_event, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    state = ExploreParams.parse(params)

    socket =
      socket
      |> assign(from: state.from, to: state.to, kinds: state.kinds)
      |> assign(z: state.z, lat: state.lat, lng: state.lng)
      |> apply_selection(state.selected_qid)
      |> push_view_state(state)

    {:noreply, socket}
  end

  # Pushed on every `handle_params/3` run, since every run is itself the
  # result of a URL change (initial load, `push_patch`, or browser
  # back/forward): the map hook's anti-loop guard (marking programmatic
  # moves) is what keeps a `map_moved`-triggered patch from re-triggering
  # itself through the `set_view` pushed back here.
  #
  # `event_selected`/`event_deselected` carry `socket.assigns.selected_qid`
  # (the *resolved* selection, set by `apply_selection/2` above), not
  # `state.selected_qid`: a `sel` naming an unknown event resolves to no
  # selection, and the hook must be told that, not the dangling qid from
  # the URL.
  defp push_view_state(socket, state) do
    if connected?(socket) do
      selected_qid = socket.assigns.selected_qid

      socket
      |> push_event("set_time_window", %{from: state.from, to: state.to})
      |> push_event("set_view", %{z: state.z, lat: state.lat, lng: state.lng})
      |> push_event(
        if(selected_qid, do: "event_selected", else: "event_deselected"),
        %{qid: selected_qid}
      )
    else
      socket
    end
  end

  @impl true
  def handle_event("select_event", %{"qid" => qid}, socket) do
    if ExploreParams.valid_qid?(qid) do
      {:noreply, push_patch(socket, to: patch_path(socket, selected_qid: qid))}
    else
      {:noreply, socket}
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

  def handle_event("set_time_window", %{"from" => from, "to" => to}, socket) do
    if ExploreParams.valid_window?(from, to) do
      {:noreply, push_patch(socket, to: patch_path(socket, from: from, to: to))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_time_window", _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="map" phx-hook="MapHook" phx-update="ignore" class="absolute inset-0"></div>
      <EventPanel.event_panel :if={@selected_event} event={@selected_event} />
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
      kinds: socket.assigns.kinds,
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
end
