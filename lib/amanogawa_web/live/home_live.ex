defmodule AmanogawaWeb.HomeLive do
  @moduledoc """
  Home page: the full-screen world map, with the timeline strip below.

  Mounts with static assigns only (no database access in `mount/3`);
  historical data loading arrives with the atlas features.
  """
  use AmanogawaWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Carte du monde")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div id="map" phx-hook="MapHook" phx-update="ignore" class="absolute inset-0"></div>
    </Layouts.app>
    """
  end
end
