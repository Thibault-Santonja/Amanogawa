defmodule AmanogawaWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AmanogawaWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: the full-screen structure of Amanogawa.

  Three stacked zones, no page scrolling: a minimal topbar, the map zone
  taking all remaining space (the inner block renders there), and a
  fixed-height strip at the bottom reserved for the timeline.

  ## Examples

      <Layouts.app flash={@flash}>
        <div id="map"></div>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden">
      <header
        id="topbar"
        class="flex h-12 shrink-0 items-center justify-between border-b border-border bg-surface px-4"
      >
        <a href="/" class="text-topbar font-topbar tracking-wide text-text">Amanogawa</a>
        <nav class="flex items-center gap-4 text-topbar text-text-muted">
          <%!-- Placeholders: Sources and About pages arrive in a later feature. --%>
          <span>Sources</span>
          <span>À propos</span>
        </nav>
      </header>

      <main id="map-zone" class="relative min-h-0 flex-1">
        {render_slot(@inner_block)}
      </main>

      <footer
        id="timeline"
        class="h-28 shrink-0 border-t border-border bg-surface"
        aria-label="Frise chronologique"
      >
        <%!-- Reserved for the timeline hook (F04). --%>
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
