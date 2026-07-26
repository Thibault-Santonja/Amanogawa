defmodule AmanogawaWeb.ConflictsLive do
  @moduledoc """
  `/relecture/conflits` (issue #035): the minimal reviewer page for
  examining sync divergences (F08 overview's "table à examiner par les
  relecteurs"). Lists every open conflict, chronologically, and lets a
  reviewer resolve each with a mandatory public motive: keep the local
  correction (refreshes the override's Wikidata snapshot) or adopt
  Wikidata's incoming value (releases the field back to it).

  Deliberately minimal: the richer review queue (diffs, appeals) is
  issue #037's `/relecture`, not this page.

  First route of `live_session :require_reviewer`
  (`AmanogawaWeb.Router`, hooks written in this same issue): an
  anonymous or non-reviewer socket never reaches `mount/3` here,
  `AmanogawaWeb.UserAuth.on_mount(:require_reviewer, ...)` redirects it
  first.

  `mount/3` assigns defaults only; conflicts are loaded in
  `handle_params/3` (`.claude/rules/liveview.md`, no database query in
  `mount/3`), held in a stream (collections belong in streams, not
  assigns).
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.HistoricalDate
  alias Amanogawa.HistoricalDate.Formatter

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Conflits de synchronisation"))
     |> stream(:conflicts, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    rows = Contributions.list_open_conflicts() |> Enum.map(&conflict_row/1)

    {:noreply, stream(socket, :conflicts, rows, reset: true)}
  end

  defp conflict_row(conflict) do
    override = Contributions.get_override(conflict.override_id)
    event = Atlas.get_event_by_qid(conflict.event_qid)

    %{
      id: conflict.id,
      event_qid: conflict.event_qid,
      event_label: event && (event.label_fr || event.label_en),
      field: conflict.field,
      field_label: field_label(conflict.field),
      override_value: format_value(conflict.field, override && override.proposed_value),
      wikidata_value: format_value(conflict.field, conflict.wikidata_value),
      detected_at: conflict.detected_at
    }
  end

  # ---------------------------------------------------------------------
  # Human-readable values (i18n review finding: never `inspect/1`'s raw
  # Elixir terms in a UI), formatted per the conflict's own field, with
  # `Amanogawa.Contributions.Conflict`'s reserved absent marker and any
  # forged/legacy payload both degrading to an honest label instead of a
  # crash.
  # ---------------------------------------------------------------------

  defp format_value(_field, nil), do: gettext("aucune valeur")
  defp format_value(_field, %{"absent" => true}), do: gettext("aucune valeur")

  defp format_value(field, %{"value" => value}) when field in [:label_fr, :label_en],
    do: value

  defp format_value(field, %{"year" => _year} = payload) when field in [:begin_date, :end_date],
    do: format_date_payload(payload)

  defp format_value(:position, %{"lon" => lon, "lat" => lat}), do: "#{lat}, #{lon}"
  defp format_value(_field, _payload), do: gettext("valeur illisible")

  defp format_date_payload(payload) do
    attrs = %{
      year: payload["year"],
      month: payload["month"],
      day: payload["day"],
      precision: payload["precision"],
      calendar: calendar_atom(payload["calendar"])
    }

    case HistoricalDate.new(attrs) do
      {:ok, date} -> Formatter.format(date)
      {:error, _changeset} -> gettext("valeur illisible")
    end
  end

  # Total conversion (security review, calendar finding): stored jsonb,
  # never fed to `String.to_existing_atom/1`.
  defp calendar_atom("gregorian"), do: :gregorian
  defp calendar_atom("julian"), do: :julian
  defp calendar_atom(_other), do: nil

  defp field_label(:label_fr), do: gettext("Libellé (français)")
  defp field_label(:label_en), do: gettext("Libellé (anglais)")
  defp field_label(:begin_date), do: gettext("Date de début")
  defp field_label(:end_date), do: gettext("Date de fin")
  defp field_label(:position), do: gettext("Position")

  # `resolution` is allowlisted BEFORE any atom conversion (security
  # review, minor 4): a forged form payload never reaches
  # `String.to_existing_atom/1`, and the system-only `:obsolete`
  # resolution is unreachable from this form by construction.
  @impl true
  def handle_event(
        "resolve",
        %{"conflict_id" => id, "resolution" => resolution, "message" => message},
        socket
      )
      when resolution in ["kept_override", "adopted_wikidata"] do
    reviewer = socket.assigns.current_scope.user
    attrs = %{resolution: String.to_existing_atom(resolution), message: message}

    case Contributions.resolve_conflict(id, reviewer, attrs) do
      {:ok, resolved} ->
        {:noreply,
         socket
         |> stream_delete(:conflicts, %{id: resolved.id})
         |> put_flash(:info, gettext("Conflit résolu."))}

      {:error, :message_required} ->
        {:noreply, put_flash(socket, :error, gettext("Un motif est requis."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Impossible de résoudre ce conflit."))}
    end
  end

  def handle_event("resolve", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Impossible de résoudre ce conflit."))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <p class="text-text-muted">
        {gettext(
          "Chaque ligne est une divergence détectée entre la valeur corrigée localement et la valeur actuelle de Wikidata."
        )}
      </p>

      <ul id="conflicts" phx-update="stream" class="mt-4 space-y-4">
        <li
          :for={{dom_id, row} <- @streams.conflicts}
          id={dom_id}
          class="rounded-md border border-border bg-surface p-4"
        >
          <p class="font-semibold text-text">
            {row.event_label || row.event_qid} <span class="text-text-muted">({row.event_qid})</span>
          </p>
          <p class="text-sm text-text-muted">{gettext("Champ :")} {row.field_label}</p>
          <div class="mt-2 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
            <p>
              <span class="font-semibold text-text">{gettext("Correction locale :")}</span>
              {row.override_value}
            </p>
            <p>
              <span class="font-semibold text-text">{gettext("Wikidata :")}</span>
              {row.wikidata_value}
            </p>
          </div>
          <p class="mt-1 text-xs text-text-muted">
            {gettext("Détecté le :")} {Calendar.strftime(row.detected_at, gettext("%d/%m/%Y %H:%M"))}
          </p>

          <form phx-submit="resolve" class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end">
            <input type="hidden" name="conflict_id" value={row.id} />
            <label class="flex-1 text-sm text-text-muted">
              {gettext("Motif (obligatoire)")}
              <textarea
                name="message"
                required
                class="mt-1 w-full rounded-md border border-border bg-surface px-2 py-1 text-sm text-text"
              ></textarea>
            </label>
            <div class="flex gap-2">
              <.button type="submit" name="resolution" value="kept_override">
                {gettext("Garder la correction")}
              </.button>
              <.button type="submit" name="resolution" value="adopted_wikidata" variant="primary">
                {gettext("Adopter Wikidata")}
              </.button>
            </div>
          </form>
        </li>
      </ul>
    </Layouts.page>
    """
  end
end
