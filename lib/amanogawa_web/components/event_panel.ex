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

  Accessibility (security review, a11y finding): the `<aside>` carries an
  `aria-label` (it has no visible heading of its own beyond the event
  title, which a screen reader would otherwise announce with no context),
  closes on Escape (`phx-window-keydown`, bound only while the panel is in
  the DOM, i.e. only "when open" by construction: `:if={@selected_event}`
  in `AmanogawaWeb.ExploreLive` mounts and unmounts this component, it is
  never merely hidden), and receives focus as soon as it mounts
  (`phx-mounted`, `tabindex="-1"` since the `<aside>` itself is not
  otherwise an interactive element) so a keyboard/screen-reader user
  selecting a marker lands inside the panel rather than the focus staying
  stranded on the map.

  ## Proposing a correction (issue #036)

  A discrete disclosure (`<details>`, no aggressive call-to-action,
  F08 overview's anti-dark-patterns principle: the panel is first a
  consultation sheet) lists the six correctable targets (the five
  `Amanogawa.Contributions.Override.field_names/0` plus a new typed
  link). The contribution is a right displayed to EVERY visitor
  (`.claude/rules/security.md`'s "droit affiché, pas un privilège
  caché"): a signed-in visitor's entry `patch`es straight into
  `AmanogawaWeb.Live.ProposalFormComponent` (state survives a refresh,
  the query string is the source of truth); an anonymous visitor's entry
  is a real link to `AmanogawaWeb.ProposalController`, which stashes the
  return path (`AmanogawaWeb.UserAuth.require_authenticated_user/2`'s
  `"user_return_to"`, F07's own mechanic) before bouncing to
  `/connexion`, so signing in comes back to this exact event with the
  chosen field already selected.

  ## Transparency section (issue #038)

  A sober footer (counts + a link, never a competing call-to-action to
  the consultation content above): the number of accepted and pending
  corrections for this event, and a link filtered to `/contributions?
  event=<qid>`. Renders NOTHING when both counts are zero (F08 overview's
  own point d'attention: "un événement vierge ne montre aucune section
  vide bavarde"). Fed by `Amanogawa.Contributions.
  event_contribution_summary/1`, computed ONCE by `AmanogawaWeb.
  ExploreLive.load_selection/2` alongside `selected_event` (never inside
  this function component itself: a stateless component's body reruns on
  every parent render, which would turn one click into a query on every
  unrelated re-render of the page it sits in), passed down as
  `:contribution_summary`.

  Any field currently listed in `@event.overridden_fields` (already
  loaded with the event, `Amanogawa.Atlas.Event`, this component never
  queries for it) additionally shows a discrete "valeur corrigée par la
  communauté" mention, linking to the exact contribution that produced
  it (`contribution_summary.accepted_override_ids_by_field`): the visitor
  always knows whether they are reading Wikidata's own value or a local
  correction.
  """

  use AmanogawaWeb, :html

  alias Amanogawa.Atlas.Event
  alias Amanogawa.HistoricalDate.Formatter

  # The five `:field` overridable business names, plus the literal
  # `"link"` (issue #036): mirrors, but never calls,
  # `Amanogawa.Contributions.Override.field_names/0` (a web component
  # reaching into another context's internal enum would itself be a
  # boundary violation, `.claude/rules/architecture.md`).
  @correction_fields ~w(label_fr label_en begin_date end_date position link)

  attr :event, Event, required: true
  attr :current_scope, Amanogawa.Accounts.Scope, required: true
  attr :contribution_summary, :map, required: true

  # The current window/camera/selection as query params (built by
  # `AmanogawaWeb.ExploreLive.view_query/1`): merged into every correction
  # link below so opening the proposal form never resets the time window
  # or the camera the visitor was looking at (quality review m-finding).
  attr :view_query, :map, default: %{}

  def event_panel(assigns) do
    assigns = assign(assigns, :correction_fields, @correction_fields)

    ~H"""
    <aside
      id="event-panel"
      class="absolute inset-y-0 right-0 w-full max-w-sm overflow-y-auto border-l border-border bg-surface p-4 shadow-lg sm:w-96"
      aria-label={gettext("Détails de l'événement")}
      tabindex="-1"
      phx-window-keydown="deselect_event"
      phx-key="Escape"
      phx-mounted={JS.focus()}
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

      <details class="mt-4 border-t border-border pt-3" id="propose-correction">
        <summary class="cursor-pointer text-sm text-text-muted hover:text-text">
          {gettext("Proposer une correction")}
        </summary>
        <ul class="mt-2 space-y-1 text-sm">
          <li :for={field <- @correction_fields}>
            <.link
              :if={@current_scope.user}
              patch={correction_patch(@view_query, @event.qid, field)}
              class="text-accent hover:underline"
            >
              {correction_label(field)}
            </.link>
            <.link
              :if={!@current_scope.user}
              href={correction_href(@view_query, @event.qid, field)}
              class="text-accent hover:underline"
            >
              {correction_label(field)}
            </.link>
          </li>
        </ul>
      </details>

      <div
        :if={show_contribution_section?(@contribution_summary)}
        class="mt-4 border-t border-border pt-3 text-sm text-text-muted"
      >
        <p>
          {gettext("%{accepted} correction(s) acceptée(s), %{pending} en attente.",
            accepted: @contribution_summary.accepted_count,
            pending: @contribution_summary.pending_count
          )}
        </p>
        <.link
          navigate={"/contributions?event=#{URI.encode_www_form(@event.qid)}"}
          class="text-accent hover:underline"
        >
          {gettext("Voir l'historique")}
        </.link>

        <p :for={field <- @event.overridden_fields} class="mt-2">
          {gettext("Valeur corrigée par la communauté, source à l'appui.")}
          <.link
            :if={@contribution_summary.accepted_override_ids_by_field[field]}
            navigate={"/contributions/#{@contribution_summary.accepted_override_ids_by_field[field]}"}
            class="text-accent hover:underline"
          >
            {gettext("Voir la contribution")}
          </.link>
        </p>
      </div>
    </aside>
    """
  end

  defp show_contribution_section?(%{accepted_count: 0, pending_count: 0}), do: false
  defp show_contribution_section?(_summary), do: true

  defp label(event), do: event.label_fr || event.label_en || event.qid
  defp extract(event), do: event.extract_fr || event.extract_en
  defp wiki_url(event), do: event.wiki_url_fr || event.wiki_url_en

  defp correction_label("label_fr"), do: gettext("Libellé (français)")
  defp correction_label("label_en"), do: gettext("Libellé (anglais)")
  defp correction_label("begin_date"), do: gettext("Date de début")
  defp correction_label("end_date"), do: gettext("Date de fin")
  defp correction_label("position"), do: gettext("Position")
  defp correction_label("link"), do: gettext("Lien vers un autre événement")

  # Both links carry the whole current view (`@view_query`, window and
  # camera included) on top of the selection and the chosen field: the
  # signed-in patch keeps the map exactly where it is, and the anonymous
  # `/proposer` round trip (`AmanogawaWeb.ProposalController` forwards
  # these params) comes back from `/connexion` to the same view too.
  defp correction_patch(view_query, qid, field) do
    query = view_query |> Map.put("sel", qid) |> Map.put("propose_field", field)
    "/?" <> URI.encode_query(query)
  end

  defp correction_href(view_query, qid, field) do
    query = view_query |> Map.put("sel", qid) |> Map.put("field", field)
    "/proposer?" <> URI.encode_query(query)
  end
end
