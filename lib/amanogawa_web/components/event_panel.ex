defmodule AmanogawaWeb.Components.EventPanel do
  @moduledoc """
  The event panel (issue #016): the full-detail sheet opened when a marker
  is selected on the map (`AmanogawaWeb.ExploreLive`). Renders the title,
  the begin date formatted strictly according to its precision (ADR 0006,
  `Amanogawa.HistoricalDate.Formatter`), the complete Wikipedia extract
  when one has been fetched, the thumbnail when present, the CC BY-SA 4.0
  attribution, a "Lire sur Wikipedia" button (`target="_blank" rel="noopener
  noreferrer"`, a licensing obligation, not a cosmetic detail,
  `.claude/rules/ethics.md`) and a close button.

  Fed directly from the `Amanogawa.Atlas.Event` struct the LiveView already
  loaded for the selection (`handle_params/3`, never `mount/3`): unlike the
  hover card, the panel is server-rendered and needs no extra HTTP round
  trip. The extract is HEEx-interpolated text, never `raw/1`: Phoenix
  escapes it by default, which is what keeps a hostile extract (a
  `<script>` tag smuggled through a compromised Wikipedia article) inert
  (`.claude/rules/security.md`).
  """

  use AmanogawaWeb, :html

  alias Amanogawa.Atlas.Event
  alias Amanogawa.HistoricalDate.Formatter

  attr :event, Event, required: true

  def event_panel(assigns) do
    ~H"""
    <aside
      id="event-panel"
      class="absolute inset-y-0 right-0 w-full max-w-sm overflow-y-auto border-l border-border bg-surface p-4 shadow-lg sm:w-96"
    >
      <div class="flex items-start justify-between gap-2">
        <h2 class="text-lg font-semibold text-text">{label(@event)}</h2>
        <button
          type="button"
          phx-click="deselect_event"
          aria-label={gettext("Fermer")}
          class="shrink-0 text-text-muted hover:text-text"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <p class="mt-1 text-sm text-text-muted">{Formatter.format(Event.begin_date(@event))}</p>

      <img
        :if={@event.thumbnail_url}
        src={@event.thumbnail_url}
        alt={label(@event)}
        class="mt-3 w-full rounded-md object-cover"
      />

      <p :if={extract(@event)} class="mt-3 text-sm text-text">{extract(@event)}</p>

      <p :if={extract(@event)} class="mt-2 text-xs text-text-muted">
        {gettext("Texte")} : Wikipédia, CC BY-SA 4.0
      </p>

      <a
        :if={wiki_url(@event)}
        href={wiki_url(@event)}
        target="_blank"
        rel="noopener noreferrer"
        class="mt-3 inline-flex items-center gap-1 text-sm font-medium text-accent hover:underline"
      >
        {gettext("Lire sur Wikipédia")}
        <.icon name="hero-arrow-top-right-on-square" class="size-4" />
      </a>
    </aside>
    """
  end

  defp label(event), do: event.label_fr || event.label_en || event.qid
  defp extract(event), do: event.extract_fr || event.extract_en
  defp wiki_url(event), do: event.wiki_url_fr || event.wiki_url_en
end
