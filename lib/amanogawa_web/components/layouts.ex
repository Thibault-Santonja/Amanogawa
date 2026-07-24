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

  The `:timeline` slot (issue #020) renders inside the fixed-height
  `footer#timeline` strip, reserved chrome (border, aria-label) that stays
  in the layout since it wraps every page; the slot content itself is the
  `TimelineHook` container, owned by whichever LiveView renders it
  (`AmanogawaWeb.ExploreLive`), so the layout never hardcodes a second
  `id="timeline"` element.

  ## Examples

      <Layouts.app flash={@flash}>
        <div id="map"></div>
        <:timeline>
          <div id="timeline-hook" phx-hook="TimelineHook" phx-update="ignore"></div>
        </:timeline>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true
  slot :timeline, doc: "the TimelineHook container (issue #020), rendered inside footer#timeline"

  def app(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden">
      <.topbar current_scope={@current_scope} />

      <main id="map-zone" class="relative min-h-0 flex-1">
        {render_slot(@inner_block)}
        <.legal_footer id="legal-footer" class="absolute inset-x-0 bottom-0 bg-surface/90" />
      </main>

      <footer
        id="timeline"
        class="h-28 shrink-0 border-t border-border bg-surface"
        aria-label={gettext("Frise chronologique")}
      >
        {render_slot(@timeline)}
      </footer>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders the static content layout used by `AmanogawaWeb.PageController`
  (issue #027: Sources/About, legal notice, privacy policy), and, since
  issue #032, `AmanogawaWeb.LoginLive`, `AmanogawaWeb.AccountLive`, and
  `AmanogawaWeb.SessionController`'s confirmation page. Unlike `app/1`
  above, `main` scrolls normally: these are ordinary text pages, not the
  full-screen map.

  `flash` defaults to an empty map rather than being required: the three
  sessionless static pages (`AmanogawaWeb.PageController`, `:static_page`
  router pipeline) never fetch flash at all (no `:fetch_session`, so no
  form on those pages ever has one to show, and no cookie is ever written
  for them, `AmanogawaWeb.Router`'s own rationale) and simply never pass
  this attribute; the account/login/session pages, all on `:browser`
  (`:fetch_live_flash`), pass their own `@flash`.
  """
  attr :page_title, :string, required: true

  attr :current_scope, :map,
    default: nil,
    doc:
      "the current [scope](https://phoenix.hexdocs.pm/scopes.html), absent on sessionless pages"

  attr :flash, :map, default: %{}, doc: "the map of flash messages, absent on sessionless pages"

  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class="flex h-dvh flex-col overflow-hidden">
      <.topbar current_scope={@current_scope} />

      <main class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto max-w-3xl px-4 py-10 text-text">
          <h1 class="mb-6 text-2xl font-semibold">{@page_title}</h1>
          {render_slot(@inner_block)}
        </div>

        <.legal_footer id="legal-footer" class="border-t border-border bg-surface" />
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The topbar shared by `app/1` and `page/1`: the site name, the
  Sources/About links (issue #027, wired to the combined `/sources` page:
  a single page serves as both the exhaustive source list and the "About"
  page, so both entries point there), and the connexion/compte link
  (issue #032).

  `current_scope` is `nil` on the sessionless static pages (`page/1`'s
  own default): shown exactly like an anonymous visitor's `nil`-user
  scope, since a page with no session cannot know whether the visitor
  holds one elsewhere (`.claude/rules/architecture.md`'s "aucun cookie"
  promise for those pages stays true either way).
  """
  attr :current_scope, :map, default: nil

  def topbar(assigns) do
    ~H"""
    <header
      id="topbar"
      class="flex h-12 shrink-0 items-center justify-between border-b border-border bg-surface px-4"
    >
      <a href="/" class="text-topbar font-topbar tracking-wide text-text">Amanogawa</a>
      <nav class="flex items-center gap-4 text-topbar text-text-muted">
        <.link href={~p"/sources"} class="hover:text-text">{gettext("Sources")}</.link>
        <.link href={~p"/sources"} class="hover:text-text">{gettext("À propos")}</.link>
        <.auth_link current_scope={@current_scope} />
      </nav>
    </header>
    """
  end

  @doc false
  attr :current_scope, :map, default: nil

  def auth_link(%{current_scope: %{user: %{email: _email}}} = assigns) do
    ~H"""
    <.link href={~p"/compte"} class="hover:text-text">{@current_scope.user.email}</.link>
    <.link href={~p"/deconnexion"} method="delete" class="hover:text-text">
      {gettext("Déconnexion")}
    </.link>
    """
  end

  def auth_link(assigns) do
    ~H"""
    <.link href={~p"/connexion"} class="hover:text-text">{gettext("Connexion")}</.link>
    """
  end

  @doc """
  The site-wide legal footer (issue #027): links to the three static
  pages plus the AGPL-3.0 source-offer notice (article 13 AGPL, satisfied
  by linking the deployed service to its own source repository).

  Rendered twice: as the real page footer on the static pages (`page/1`),
  and as a compact overlay docked to the bottom of the map viewport on the
  full-screen app layout (`app/1`), so the same attributions and legal
  links stay reachable from the home page without adding a fourth
  fixed-height flex zone to the `h-dvh` layout.
  """
  attr :id, :string, required: true
  attr :class, :string, default: nil

  def legal_footer(assigns) do
    ~H"""
    <footer id={@id} class={["px-4 py-2 text-xs text-text-muted", @class]}>
      <nav class="mx-auto flex max-w-3xl flex-wrap items-center gap-x-4 gap-y-1">
        <.link href={~p"/sources"} class="hover:text-text">{gettext("Sources")}</.link>
        <.link href={~p"/mentions-legales"} class="hover:text-text">
          {gettext("Mentions légales")}
        </.link>
        <.link href={~p"/confidentialite"} class="hover:text-text">
          {gettext("Confidentialité")}
        </.link>
        <a
          href="https://github.com/Thibault-Santonja/Amanogawa"
          target="_blank"
          rel="noopener noreferrer"
          class="hover:text-text"
        >
          {gettext("Code source sous licence AGPL-3.0")}
        </a>
      </nav>
    </footer>
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
