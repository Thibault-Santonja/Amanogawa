defmodule AmanogawaWeb.ContributionsLive do
  @moduledoc """
  `/contributions` (issue #038): the public, strictly chronological feed
  of every contribution (F08 overview / ADR 0008: "flux chronologique
  PUR, aucun tri algorithmique"). Every visitor may open it, signed in or
  not, same `live_session :current_user` as `AmanogawaWeb.ExploreLive` and
  `AmanogawaWeb.ContributionLive`.

  Filters are FACTUAL only (`?status=`, `?event=`) and live in the URL
  (shareable, per the issue): `Amanogawa.Contributions.list_public/1`
  itself drops an unknown status or a malformed event id rather than
  raising, so a hand-edited query string never 500s this page, it just
  falls back to "no such filter". Pagination is a sober "charger plus"
  button (issue #038's own anti-dark-patterns wording), NOT part of the
  URL: only the filters need to be shareable, not "page 3".

  `mount/3` assigns defaults only; every page of rows is loaded from
  `handle_params/3` (initial filters) or the "load_more" event
  (`.claude/rules/liveview.md`), held in a stream. Attribution is
  resolved once per page (`AmanogawaWeb.Contributions.Attribution`,
  never one query per row).
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias AmanogawaWeb.Contributions.Attribution

  # Overridable via `config :amanogawa, #{inspect(__MODULE__)}, page_size:`
  # (same mechanic as `AmanogawaWeb.ExploreLive`'s own `selection_rate_
  # limit`): lets tests reach "has_more?" with a handful of rows instead
  # of twenty.
  @default_page_size 20

  # Mirrors, but never calls, `Amanogawa.Contributions.Override`'s own
  # `@type status` (a web-layer filter list reaching into a domain
  # schema's private attribute would itself be a boundary violation,
  # `.claude/rules/architecture.md`; same reasoning as `AmanogawaWeb.
  # Components.EventPanel`'s own `@correction_fields`).
  @statuses ~w(pending accepted rejected appealed superseded)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Contributions"))
     |> assign(:statuses, @statuses)
     |> assign(:has_more?, false)
     |> assign(:cursor, nil)
     |> assign(:empty?, false)
     |> stream(:contributions, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filters = %{status: params["status"], event_qid: params["event"]}

    {:noreply,
     socket
     |> assign(:raw_status, params["status"])
     |> assign(:raw_event, params["event"])
     |> assign(:filters, filters)
     |> load_page(filters, nil, reset: true)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    {:noreply, load_page(socket, socket.assigns.filters, socket.assigns.cursor, reset: false)}
  end

  defp load_page(socket, filters, cursor, opts) do
    page_size = page_size()

    fetch_opts =
      filters
      |> Map.put(:after, cursor)
      |> Map.put(:limit, page_size + 1)

    overrides = Contributions.list_public(fetch_opts)
    {page, has_more?} = split_page(overrides, page_size)

    names = page |> Enum.map(& &1.author_id) |> Attribution.resolve_names()
    rows = Enum.map(page, &build_row(&1, names))

    next_cursor =
      case List.last(page) do
        nil -> cursor
        override -> %{inserted_at: override.inserted_at, id: override.id}
      end

    reset? = Keyword.fetch!(opts, :reset)
    empty? = reset? && rows == []

    socket
    |> stream(:contributions, rows, reset: reset?)
    |> assign(:has_more?, has_more?)
    |> assign(:cursor, next_cursor)
    |> assign(:empty?, empty?)
  end

  defp page_size do
    Application.get_env(:amanogawa, __MODULE__, []) |> Keyword.get(:page_size, @default_page_size)
  end

  defp split_page(rows, page_size) do
    case Enum.split(rows, page_size) do
      {page, []} -> {page, false}
      {page, _rest} -> {page, true}
    end
  end

  defp build_row(override, names) do
    event = override.event_qid && Atlas.get_event_by_qid(override.event_qid)

    %{
      id: override.id,
      inserted_at: override.inserted_at,
      author_name: Attribution.name(names, override.author_id, gettext("compte supprimé")),
      status: override.status,
      kind: override.kind,
      field: override.field,
      event_qid: override.event_qid,
      event_label: event_label(event, override)
    }
  end

  defp event_label(nil, %{kind: :new_event}), do: gettext("Nouvel événement proposé")
  defp event_label(nil, override), do: override.event_qid
  defp event_label(event, _override), do: event.label_fr || event.label_en || event.qid

  defp filter_path(status, event) do
    query =
      %{}
      |> put_query("status", status)
      |> put_query("event", event)
      |> URI.encode_query()

    if query == "", do: "/contributions", else: "/contributions?#{query}"
  end

  defp put_query(query, _key, nil), do: query
  defp put_query(query, key, value), do: Map.put(query, key, value)

  defp status_label("pending"), do: gettext("En attente")
  defp status_label("accepted"), do: gettext("Acceptée")
  defp status_label("rejected"), do: gettext("Rejetée")
  defp status_label("appealed"), do: gettext("En appel")
  defp status_label("superseded"), do: gettext("Remplacée")
  defp status_label(status) when is_atom(status), do: status |> Atom.to_string() |> status_label()

  defp kind_field_label(%{kind: :field, field: field}), do: field_label(field)
  defp kind_field_label(%{kind: :link}), do: gettext("Lien entre événements")
  defp kind_field_label(%{kind: :new_event}), do: gettext("Nouvel événement")

  defp field_label(:label_fr), do: gettext("Libellé (français)")
  defp field_label(:label_en), do: gettext("Libellé (anglais)")
  defp field_label(:begin_date), do: gettext("Date de début")
  defp field_label(:end_date), do: gettext("Date de fin")
  defp field_label(:position), do: gettext("Position")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <p class="text-text-muted">
        {gettext(
          "Flux chronologique strict de toutes les contributions, de la plus récente à la plus ancienne, aucun tri algorithmique."
        )}
      </p>

      <div class="mt-4 flex flex-wrap gap-2 text-sm">
        <.link
          patch={filter_path(nil, @raw_event)}
          class={["rounded px-2 py-1", @raw_status == nil && "bg-accent/20 text-accent"]}
        >
          {gettext("Tous les statuts")}
        </.link>
        <.link
          :for={status <- @statuses}
          patch={filter_path(status, @raw_event)}
          class={["rounded px-2 py-1", @raw_status == status && "bg-accent/20 text-accent"]}
        >
          {status_label(status)}
        </.link>
      </div>

      <p :if={@raw_event} class="mt-2 text-sm text-text-muted">
        {gettext("Filtré sur l'événement :")} {@raw_event}
        <.link patch={filter_path(@raw_status, nil)} class="text-accent hover:underline">
          {gettext("retirer")}
        </.link>
      </p>

      <ul id="contributions-feed" phx-update="stream" class="mt-4 space-y-3">
        <li
          :for={{dom_id, row} <- @streams.contributions}
          id={dom_id}
          class="rounded-md border border-border bg-surface p-3"
        >
          <.link navigate={~p"/contributions/#{row.id}"} class="block">
            <p class="text-xs text-text-muted">
              {Calendar.strftime(row.inserted_at, gettext("%d/%m/%Y %H:%M"))} - {gettext("par")} {row.author_name}
            </p>
            <p class="font-semibold text-text">{row.event_label}</p>
            <p class="text-sm text-text-muted">
              {kind_field_label(row)} - {status_label(row.status)}
            </p>
          </.link>
        </li>
      </ul>

      <p :if={@empty?} class="mt-4 text-sm text-text-muted">
        {gettext("Aucune contribution pour ce filtre.")}
      </p>

      <.button :if={@has_more?} phx-click="load_more" class="mt-4">
        {gettext("Charger plus")}
      </.button>
    </Layouts.page>
    """
  end
end
