defmodule AmanogawaWeb.ContributionLive do
  @moduledoc """
  `/contributions/:id` (issue #037, completed in #038): the public detail
  page of a single contribution. Every visitor may open it, signed in or
  not (F08 overview's "historique intégralement public"): attribution
  (author, and every revision's actor), the event concerned, the before/
  after values formatted by their own precision, the source, and the
  complete, dated, chronological revision history (proposal, decision
  with its motive, appeal, appeal decision). Only the override's own author
  (anti-IDOR, `.claude/rules/security.md`), signed in, on a `:rejected`
  proposal carrying no appeal yet, sees the reply form (`Amanogawa.
  Contributions.appeal_override/3`).

  `mount/3` assigns defaults only; the override, its revisions and every
  attribution are loaded in `handle_params/3` (`.claude/rules/
  liveview.md`). Attribution is resolved ONCE per load (`AmanogawaWeb.
  Contributions.Attribution`), covering the author AND every revision's
  actor in a single query, never one per row.
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.HistoricalDate
  alias Amanogawa.HistoricalDate.Formatter
  alias AmanogawaWeb.Contributions.Attribution

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Contribution"))}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    # `Ecto.UUID.cast/1` first (security review, minor 3): a malformed id
    # in the public URL is answered with the same neutral "introuvable"
    # as an unknown one, never a raised `Ecto.Query.CastError` (a 500).
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> assign_override(socket, Contributions.get_override(uuid))
      :error -> assign_override(socket, nil)
    end
  end

  defp assign_override(socket, override) do
    case override do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Contribution introuvable."))
         |> assign(override: nil, revisions: [], can_appeal?: false, appeal_form: nil)}

      override ->
        revisions = Contributions.list_revisions(override.id)
        can_appeal? = can_appeal?(override, revisions, socket.assigns.current_scope.user)

        names =
          [override.author_id | Enum.map(revisions, & &1.actor_id)]
          |> Attribution.resolve_names()

        {:noreply,
         socket
         |> assign(:override, override)
         |> assign(:author_name, Attribution.name(names, override.author_id, deleted_label()))
         |> assign(:event_label, event_label(override))
         |> assign(:diff, build_diff(override))
         |> assign(:revisions, Enum.map(revisions, &revision_row(&1, names)))
         |> assign(:can_appeal?, can_appeal?)
         |> assign(:appeal_form, to_form(%{"text" => ""}, as: "appeal"))}
    end
  end

  defp deleted_label, do: gettext("compte supprimé")

  defp can_appeal?(_override, _revisions, nil), do: false

  defp can_appeal?(override, revisions, user) do
    override.status == :rejected and override.author_id == user.id and
      not Enum.any?(revisions, &(&1.action == :appealed))
  end

  # ---------------------------------------------------------------------
  # Event label and before/after diff (issue #038)
  # ---------------------------------------------------------------------

  defp event_label(%{kind: :new_event}), do: gettext("Nouvel événement proposé")

  defp event_label(%{event_qid: qid}) when is_binary(qid) do
    case Atlas.get_event_by_qid(qid) do
      nil -> qid
      event -> (event.label_fr || event.label_en || event.qid) <> " (#{qid})"
    end
  end

  defp build_diff(%{kind: :field, field: field} = override) do
    %{
      kind: :field,
      field: field,
      before: format_field_value(field, override.current_value),
      after_value: format_field_value(field, override.proposed_value)
    }
  end

  defp build_diff(%{kind: :link} = override) do
    target_event = Atlas.get_event_by_qid(override.target_qid)

    %{
      kind: :link,
      target_label:
        (target_event && (target_event.label_fr || target_event.label_en)) ||
          override.target_qid,
      link_type: override.link_type
    }
  end

  defp build_diff(%{kind: :new_event} = override) do
    payload = override.proposed_value

    %{
      kind: :new_event,
      label: payload["label_fr"] || payload["label_en"],
      description: payload["description_fr"] || payload["description_en"],
      begin_date: format_field_value(:begin_date, payload["begin_date"]),
      position: format_field_value(:position, payload["position"])
    }
  end

  defp format_field_value(field, payload) when field in [:label_fr, :label_en] do
    case payload do
      %{"value" => value} -> value
      _other -> nil
    end
  end

  defp format_field_value(field, payload) when field in [:begin_date, :end_date] do
    case payload do
      %{
        "year" => year,
        "month" => month,
        "day" => day,
        "precision" => precision,
        "calendar" => calendar
      } ->
        attrs = %{
          year: year,
          month: month,
          day: day,
          precision: precision,
          calendar: calendar_atom(calendar)
        }

        case HistoricalDate.new(attrs) do
          {:ok, date} -> Formatter.format(date)
          {:error, _changeset} -> nil
        end

      _other ->
        nil
    end
  end

  defp format_field_value(:position, payload) do
    case payload do
      %{"lon" => lon, "lat" => lat} -> "#{lat}, #{lon}"
      _other -> nil
    end
  end

  # Total conversion (security review, calendar finding): the payload is
  # stored jsonb on a PUBLIC page, so forged/legacy data must render as
  # "no calendar" (then usually "no value"), never crash the LiveView
  # through `String.to_existing_atom/1`.
  defp calendar_atom("gregorian"), do: :gregorian
  defp calendar_atom("julian"), do: :julian
  defp calendar_atom(_other), do: nil

  defp field_label(:label_fr), do: gettext("Libellé (français)")
  defp field_label(:label_en), do: gettext("Libellé (anglais)")
  defp field_label(:begin_date), do: gettext("Date de début")
  defp field_label(:end_date), do: gettext("Date de fin")
  defp field_label(:position), do: gettext("Position")

  defp link_type_label(:part_of), do: gettext("fait partie de")
  defp link_type_label(:follows), do: gettext("suit")
  defp link_type_label(:cause), do: gettext("cause")
  defp link_type_label(:effect), do: gettext("effet")
  defp link_type_label(:significant), do: gettext("événement notable lié")

  # ---------------------------------------------------------------------
  # Revision history (issue #038): every entry dated and attributed, an
  # action whose actor is the SYSTEM (a sync-triggered `:superseded`, or
  # the account-deletion-triggered `:anonymized`, both journalled with
  # `actor_id: nil` by design, `Amanogawa.Contributions`' own moduledoc)
  # never renders as "compte supprimé": that label is reserved for a REAL
  # person's account that was later anonymized. A `:superseded` revision
  # CARRYING an actor is a different animal (quality review): a reviewer
  # resolving a conflict by adopting Wikidata's value
  # (`Amanogawa.Contributions.resolve_conflict/3`, `:adopted_wikidata`),
  # so that decision IS attributed, with its own label.
  # ---------------------------------------------------------------------

  @system_actions [:superseded, :anonymized]

  defp revision_row(%{action: action, actor_id: nil} = revision, _names)
       when action in @system_actions do
    %{
      action: revision.action,
      action_label: action_label(revision.action),
      actor_name: nil,
      message: revision.message,
      inserted_at: revision.inserted_at
    }
  end

  defp revision_row(revision, names) do
    %{
      action: revision.action,
      action_label: attributed_action_label(revision.action),
      actor_name: Attribution.name(names, revision.actor_id, deleted_label()),
      message: revision.message,
      inserted_at: revision.inserted_at
    }
  end

  # A `:superseded` revision with an actor is a reviewer's own
  # `:adopted_wikidata` conflict resolution, never the sync.
  defp attributed_action_label(:superseded), do: gettext("Valeur Wikidata adoptée (conflit)")
  defp attributed_action_label(action), do: action_label(action)

  defp action_label(:proposed), do: gettext("Proposition")
  defp action_label(:accepted), do: gettext("Acceptée")
  defp action_label(:rejected), do: gettext("Rejetée")
  defp action_label(:appealed), do: gettext("Réponse de l'auteur")
  defp action_label(:appeal_reviewed), do: gettext("Appel tranché")
  defp action_label(:superseded), do: gettext("Remplacée (synchronisation)")
  defp action_label(:conflict_resolved), do: gettext("Conflit résolu")
  defp action_label(:anonymized), do: gettext("Auteur anonymisé (compte supprimé)")

  defp status_label(:pending), do: gettext("En attente")
  defp status_label(:accepted), do: gettext("Acceptée")
  defp status_label(:rejected), do: gettext("Rejetée")
  defp status_label(:appealed), do: gettext("En appel")
  defp status_label(:superseded), do: gettext("Remplacée")

  @impl true
  def handle_event("submit_appeal", %{"appeal" => %{"text" => text}}, socket) do
    author = socket.assigns.current_scope.user
    override = socket.assigns.override

    case Contributions.appeal_override(override.id, author, text) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> push_patch(to: ~p"/contributions/#{updated.id}")
         |> put_flash(:info, gettext("Votre réponse a été publiée."))}

      {:error, :text_required} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("La réponse doit contenir entre 5 et 1000 caractères.")
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Impossible d'envoyer cette réponse."))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <div :if={@override}>
        <p class="text-text-muted">
          {gettext("Concernant :")} <span class="font-semibold text-text">{@event_label}</span>
        </p>
        <p class="text-text-muted">{gettext("Statut :")} {status_label(@override.status)}</p>
        <p class="text-text-muted">{gettext("Proposé par")} {@author_name}</p>

        <.diff_view diff={@diff} />

        <p class="mt-2 text-text">
          <span class="font-semibold">{gettext("Source :")}</span> {@override.source}
        </p>

        <h2 class="mt-4 text-lg font-semibold text-text">{gettext("Historique")}</h2>
        <ul class="mt-2 space-y-2">
          <li :for={revision <- @revisions} class="rounded border border-border p-2 text-sm">
            <p class="font-semibold text-text">
              {revision.action_label}
              <span :if={revision.actor_name} class="font-normal text-text-muted">
                - {revision.actor_name}
              </span>
            </p>
            <p :if={revision.message} class="text-text">{revision.message}</p>
            <p class="text-xs text-text-muted">
              {Calendar.strftime(revision.inserted_at, gettext("%d/%m/%Y %H:%M"))}
            </p>
          </li>
        </ul>

        <div :if={@can_appeal?} class="mt-4">
          <h2 class="text-lg font-semibold text-text">{gettext("Répondre à ce rejet")}</h2>
          <p class="text-text-muted">
            {gettext(
              "Une seule réponse est possible ; un relecteur tranchera ensuite définitivement."
            )}
          </p>
          <.form for={@appeal_form} phx-submit="submit_appeal" class="mt-2 max-w-lg">
            <.input field={@appeal_form[:text]} type="text" label={gettext("Votre réponse")} required />
            <.button variant="primary" type="submit">{gettext("Envoyer")}</.button>
          </.form>
        </div>
      </div>
    </Layouts.page>
    """
  end

  attr :diff, :map, required: true

  defp diff_view(%{diff: %{kind: :field}} = assigns) do
    ~H"""
    <div class="mt-3 grid grid-cols-1 gap-2 text-sm sm:grid-cols-2">
      <p class="sm:col-span-2 font-semibold text-text">{field_label(@diff.field)}</p>
      <p>
        <span class="font-semibold text-text">{gettext("Avant :")}</span> {@diff.before ||
          gettext("aucune valeur")}
      </p>
      <p>
        <span class="font-semibold text-text">{gettext("Après :")}</span> {@diff.after_value ||
          gettext("aucune valeur")}
      </p>
    </div>
    """
  end

  defp diff_view(%{diff: %{kind: :link}} = assigns) do
    ~H"""
    <p class="mt-3 text-sm text-text">
      {link_type_label(@diff.link_type)} <span class="font-semibold">{@diff.target_label}</span>
    </p>
    """
  end

  defp diff_view(%{diff: %{kind: :new_event}} = assigns) do
    ~H"""
    <div class="mt-3 text-sm text-text">
      <p class="font-semibold">{@diff.label}</p>
      <p :if={@diff.description}>{@diff.description}</p>
      <p>{gettext("Date :")} {@diff.begin_date}</p>
      <p>{gettext("Position :")} {@diff.position}</p>
    </div>
    """
  end
end
