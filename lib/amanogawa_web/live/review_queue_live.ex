defmodule AmanogawaWeb.ReviewQueueLive do
  @moduledoc """
  `/relecture` (issue #037): the review queue, the heart of the V1
  moderation workflow (F08 overview). Strictly chronological FIFO
  (`Amanogawa.Contributions.list_review_queue/1`: oldest proposal first,
  appeals included at their ORIGINAL date, no algorithmic prioritization,
  ADR 0008's anti-dark-patterns principle), the only filters are factual
  (`kind`, `event_qid`).

  First route (alongside `AmanogawaWeb.ConflictsLive`) of
  `live_session :require_reviewer` (`AmanogawaWeb.Router`, hooks written
  in #035): an anonymous or non-reviewer socket never reaches `mount/3`
  here.

  `mount/3` assigns defaults only; the queue is loaded in
  `handle_params/3` (`.claude/rules/liveview.md`), held in a stream.
  Every row carries its own typed diff (dates formatted per precision by
  `Amanogawa.HistoricalDate.Formatter`, ADR 0006; position with an
  approximate distance; link with both endpoints' labels; a full sheet
  for a new event) and a "reference value changed since proposal" badge
  when the event's CURRENT state (read live through `Amanogawa.Atlas`)
  no longer matches the snapshot taken at proposal time
  (`Amanogawa.Contributions.Override.current_value`).
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Accounts
  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.HistoricalDate
  alias Amanogawa.HistoricalDate.Formatter

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("File de relecture"))
     |> stream(:queue, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    filters =
      %{}
      |> put_filter(:kind, params["kind"])
      |> put_filter(:event_qid, params["event_qid"])

    rows = filters |> Contributions.list_review_queue() |> Enum.map(&build_row/1)

    {:noreply, stream(socket, :queue, rows, reset: true)}
  end

  defp put_filter(filters, _key, nil), do: filters
  defp put_filter(filters, _key, ""), do: filters

  defp put_filter(filters, :kind, value),
    do: Map.put(filters, :kind, String.to_existing_atom(value))

  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  defp build_row(override) do
    author_name = Accounts.display_names_by_ids([override.author_id])[override.author_id]
    appeal_text = appeal_text(override)

    %{
      id: override.id,
      override: override,
      kind: override.kind,
      status: override.status,
      author_name: author_name || gettext("compte supprimé"),
      source: override.source,
      inserted_at: override.inserted_at,
      appeal_text: appeal_text,
      diff: build_diff(override)
    }
  end

  defp appeal_text(%{status: :appealed} = override) do
    override.id
    |> Contributions.list_revisions()
    |> Enum.reverse()
    |> Enum.find(&(&1.action == :appealed))
    |> case do
      nil -> nil
      revision -> revision.message
    end
  end

  defp appeal_text(_override), do: nil

  # ---------------------------------------------------------------------
  # Typed diff (issue #037)
  # ---------------------------------------------------------------------

  defp build_diff(%{kind: :field, field: field} = override)
       when field in [:label_fr, :label_en] do
    %{
      kind: :label,
      before: value_of(override.current_value),
      after_value: value_of(override.proposed_value),
      reference_changed?: reference_changed?(override)
    }
  end

  defp build_diff(%{kind: :field, field: field} = override)
       when field in [:begin_date, :end_date] do
    %{
      kind: :date,
      before: format_date_payload(override.current_value),
      after_value: format_date_payload(override.proposed_value),
      reference_changed?: reference_changed?(override)
    }
  end

  defp build_diff(%{kind: :field, field: :position} = override) do
    before_position = override.current_value
    after_position = override.proposed_value

    %{
      kind: :position,
      before: format_position(before_position),
      after_value: format_position(after_position),
      distance_km: distance_km(before_position, after_position),
      map_url:
        after_position && "/?lat=#{after_position["lat"]}&lng=#{after_position["lon"]}&z=10",
      reference_changed?: reference_changed?(override)
    }
  end

  defp build_diff(%{kind: :link} = override) do
    source_event = Atlas.get_event_by_qid(override.event_qid)
    target_event = Atlas.get_event_by_qid(override.target_qid)

    %{
      kind: :link,
      source_label: source_event && label(source_event),
      target_label: (target_event && label(target_event)) || override.target_qid,
      link_type: override.link_type
    }
  end

  defp build_diff(%{kind: :new_event} = override) do
    payload = override.proposed_value

    %{
      kind: :new_event,
      label_fr: payload["label_fr"],
      label_en: payload["label_en"],
      description_fr: payload["description_fr"],
      description_en: payload["description_en"],
      begin_date: format_date_payload(payload["begin_date"]),
      position: format_position(payload["position"])
    }
  end

  defp value_of(nil), do: nil
  defp value_of(payload), do: payload["value"]

  defp format_date_payload(nil), do: nil

  defp format_date_payload(payload) do
    attrs = %{
      year: payload["year"],
      month: payload["month"],
      day: payload["day"],
      precision: payload["precision"],
      calendar: payload["calendar"] && String.to_existing_atom(payload["calendar"])
    }

    case HistoricalDate.new(attrs) do
      {:ok, date} -> Formatter.format(date)
      {:error, _changeset} -> nil
    end
  end

  defp format_position(nil), do: nil
  defp format_position(%{"lon" => lon, "lat" => lat}), do: "#{lat}, #{lon}"

  # Haversine distance, kilometers, rounded to the unit: an
  # approximation is all a reviewer needs to judge "a typo" from "a
  # different city" (issue #037's own wording).
  @earth_radius_km 6371

  defp distance_km(%{"lon" => lon1, "lat" => lat1}, %{"lon" => lon2, "lat" => lat2}) do
    phi1 = deg2rad(lat1)
    phi2 = deg2rad(lat2)
    dphi = deg2rad(lat2 - lat1)
    dlambda = deg2rad(lon2 - lon1)

    a =
      :math.sin(dphi / 2) * :math.sin(dphi / 2) +
        :math.cos(phi1) * :math.cos(phi2) * :math.sin(dlambda / 2) * :math.sin(dlambda / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    round(@earth_radius_km * c)
  end

  defp distance_km(_before, _after), do: nil

  defp deg2rad(degrees), do: degrees * :math.pi() / 180

  # A reviewer's decision motive is mandatory (`Amanogawa.Contributions.
  # accept_override/3` already enforces this in the domain; re-validated
  # here only to render a targeted error rather than a generic one).
  defp reference_changed?(%{kind: :field, event_qid: qid, field: field, current_value: snapshot}) do
    case Atlas.get_event_by_qid(qid) do
      nil -> false
      event -> field_current_value(field, event) != snapshot
    end
  end

  defp reference_changed?(_override), do: false

  defp field_current_value(:label_fr, event), do: %{"value" => event.label_fr}
  defp field_current_value(:label_en, event), do: %{"value" => event.label_en}

  defp field_current_value(:begin_date, event) do
    date_payload(
      event.begin_year,
      event.begin_month,
      event.begin_day,
      event.begin_precision,
      event.begin_calendar
    )
  end

  defp field_current_value(:end_date, event) do
    date_payload(
      event.end_year,
      event.end_month,
      event.end_day,
      event.end_precision,
      event.end_calendar
    )
  end

  defp field_current_value(:position, %{geom: nil}), do: nil

  defp field_current_value(:position, %{geom: %Geo.Point{coordinates: {lon, lat}}}) do
    %{"lon" => Float.round(lon / 1, 6), "lat" => Float.round(lat / 1, 6)}
  end

  defp date_payload(nil, _month, _day, _precision, _calendar), do: nil

  defp date_payload(year, month, day, precision, calendar) do
    %{
      "year" => year,
      "month" => month,
      "day" => day,
      "precision" => precision,
      "calendar" => calendar && Atom.to_string(calendar)
    }
  end

  defp label(event), do: event.label_fr || event.label_en || event.qid

  # ---------------------------------------------------------------------
  # Decisions
  # ---------------------------------------------------------------------

  @impl true
  def handle_event(
        "decide",
        %{"override_id" => id, "decision" => decision, "message" => message},
        socket
      ) do
    reviewer = socket.assigns.current_scope.user

    decide(decision, id, reviewer, message)
    |> case do
      {:ok, override} ->
        {:noreply,
         socket
         |> stream_delete(:queue, %{id: override.id})
         |> put_flash(:info, decision_flash(decision))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, decision_error(reason))}
    end
  end

  def handle_event(
        "review_appeal",
        %{"override_id" => id, "decision" => decision, "message" => message},
        socket
      ) do
    reviewer = socket.assigns.current_scope.user
    attrs = %{decision: String.to_existing_atom(decision), message: message}

    case Contributions.review_appeal(id, reviewer, attrs) do
      {:ok, override} ->
        {:noreply,
         socket
         |> stream_delete(:queue, %{id: override.id})
         |> put_flash(:info, gettext("Appel tranché."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, decision_error(reason))}
    end
  end

  defp decide("accept", id, reviewer, message),
    do: Contributions.accept_override(id, reviewer, message)

  defp decide("reject", id, reviewer, message),
    do: Contributions.reject_override(id, reviewer, message)

  defp decision_flash("accept"), do: gettext("Proposition acceptée.")
  defp decision_flash("reject"), do: gettext("Proposition rejetée.")

  defp decision_error(:message_required), do: gettext("Un motif est requis.")

  defp decision_error(:self_review),
    do: gettext("Vous ne pouvez pas relire votre propre proposition.")

  defp decision_error(_other), do: gettext("Impossible de traiter cette décision.")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <p class="text-text-muted">
        {gettext(
          "File chronologique stricte (la plus ancienne proposition d'abord), aucun tri algorithmique."
        )}
      </p>

      <ul id="review-queue" phx-update="stream" class="mt-4 space-y-4">
        <li
          :for={{dom_id, row} <- @streams.queue}
          id={dom_id}
          class="rounded-md border border-border bg-surface p-4"
        >
          <div class="flex items-center justify-between gap-2">
            <p class="font-semibold text-text">
              {gettext("Par")} {row.author_name}
              <span
                :if={row.status == :appealed}
                class="ml-2 rounded bg-accent/20 px-2 py-0.5 text-xs text-accent"
              >
                {gettext("En appel")}
              </span>
            </p>
            <p class="text-xs text-text-muted">
              {Calendar.strftime(row.inserted_at, gettext("%d/%m/%Y %H:%M"))}
            </p>
          </div>

          <p
            :if={row.diff[:reference_changed?]}
            class="mt-2 rounded bg-warning/20 px-2 py-1 text-xs text-text"
          >
            {gettext("La valeur de référence a changé depuis la proposition.")}
          </p>

          <.diff_view diff={row.diff} />

          <p class="mt-3 text-sm text-text">
            <span class="font-semibold">{gettext("Source :")}</span> {row.source}
          </p>

          <p :if={row.appeal_text} class="mt-2 rounded border border-border p-2 text-sm text-text">
            <span class="font-semibold">{gettext("Réponse de l'auteur :")}</span> {row.appeal_text}
          </p>

          <form
            :if={row.status == :pending}
            phx-submit="decide"
            class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end"
          >
            <input type="hidden" name="override_id" value={row.id} />
            <.motive_field />
            <div class="flex gap-2">
              <.button type="submit" name="decision" value="accept" variant="primary">
                {gettext("Accepter")}
              </.button>
              <.button type="submit" name="decision" value="reject">
                {gettext("Rejeter")}
              </.button>
            </div>
          </form>

          <form
            :if={row.status == :appealed}
            phx-submit="review_appeal"
            class="mt-3 flex flex-col gap-2 sm:flex-row sm:items-end"
          >
            <input type="hidden" name="override_id" value={row.id} />
            <.motive_field />
            <div class="flex gap-2">
              <.button type="submit" name="decision" value="accepted" variant="primary">
                {gettext("Accepter l'appel")}
              </.button>
              <.button type="submit" name="decision" value="rejected">
                {gettext("Rejeter définitivement")}
              </.button>
            </div>
          </form>
        </li>
      </ul>
    </Layouts.page>
    """
  end

  defp motive_field(assigns) do
    ~H"""
    <label class="flex-1 text-sm text-text-muted">
      {gettext("Motif (obligatoire)")}
      <textarea
        name="message"
        required
        class="mt-1 w-full rounded-md border border-border bg-surface px-2 py-1 text-sm text-text"
      ></textarea>
    </label>
    """
  end

  attr :diff, :map, required: true

  defp diff_view(%{diff: %{kind: :label}} = assigns) do
    ~H"""
    <div class="mt-2 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
      <p>
        <span class="font-semibold text-text">{gettext("Avant :")}</span>
        {@diff.before || gettext("aucune")}
      </p>
      <p><span class="font-semibold text-text">{gettext("Après :")}</span> {@diff.after_value}</p>
    </div>
    """
  end

  defp diff_view(%{diff: %{kind: :date}} = assigns) do
    ~H"""
    <div class="mt-2 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
      <p>
        <span class="font-semibold text-text">{gettext("Avant :")}</span> {@diff.before ||
          gettext("aucune")}
      </p>
      <p>
        <span class="font-semibold text-text">{gettext("Après :")}</span> {@diff.after_value ||
          gettext("aucune")}
      </p>
    </div>
    """
  end

  defp diff_view(%{diff: %{kind: :position}} = assigns) do
    ~H"""
    <div class="mt-2 text-sm">
      <p>
        <span class="font-semibold text-text">{gettext("Avant :")}</span> {@diff.before ||
          gettext("aucune")}
      </p>
      <p><span class="font-semibold text-text">{gettext("Après :")}</span> {@diff.after_value}</p>
      <p :if={@diff.distance_km}>{gettext("Distance approximative :")} {@diff.distance_km} km</p>
      <a :if={@diff.map_url} href={@diff.map_url} class="text-accent hover:underline">
        {gettext("Voir sur la carte")}
      </a>
    </div>
    """
  end

  defp diff_view(%{diff: %{kind: :link}} = assigns) do
    ~H"""
    <div class="mt-2 text-sm">
      <p>
        {@diff.source_label} <.link_type_label type={@diff.link_type} /> {@diff.target_label}
      </p>
    </div>
    """
  end

  defp diff_view(%{diff: %{kind: :new_event}} = assigns) do
    ~H"""
    <div class="mt-2 text-sm">
      <p class="font-semibold text-text">{@diff.label_fr || @diff.label_en}</p>
      <p :if={@diff.description_fr || @diff.description_en}>
        {@diff.description_fr || @diff.description_en}
      </p>
      <p>{gettext("Date :")} {@diff.begin_date}</p>
      <p>{gettext("Position :")} {@diff.position}</p>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp link_type_label(%{type: :part_of} = assigns),
    do: ~H[<span>{gettext("fait partie de")}</span>]

  defp link_type_label(%{type: :follows} = assigns), do: ~H[<span>{gettext("suit")}</span>]
  defp link_type_label(%{type: :cause} = assigns), do: ~H[<span>{gettext("cause")}</span>]
  defp link_type_label(%{type: :effect} = assigns), do: ~H[<span>{gettext("effet")}</span>]

  defp link_type_label(%{type: :significant} = assigns),
    do: ~H[<span>{gettext("événement notable lié")}</span>]
end
