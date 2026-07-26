defmodule AmanogawaWeb.ContributionLive do
  @moduledoc """
  `/contributions/:id` (issue #037, completed in #038): the public detail
  page of a single contribution. The route and the appeal form are posed
  here; the full public layout (source, decision history, transparent
  moderation framing) arrives in #038, which is also where the URL a
  decision email points to (`Amanogawa.Contributions.DecisionNotifier`)
  gets its complete page.

  Under `live_session :current_user`: every visitor may open it, signed
  in or not (F08 overview's "historique intégralement public"). Only the
  override's own author (anti-IDOR, `.claude/rules/security.md`), signed
  in, on a `:rejected` proposal carrying no appeal yet, sees the reply
  form (`Amanogawa.Contributions.appeal_override/3`).

  `mount/3` assigns defaults only; the override and its revisions are
  loaded in `handle_params/3` (`.claude/rules/liveview.md`).
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Contributions

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Contribution"))}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case Contributions.get_override(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Contribution introuvable."))
         |> assign(override: nil, revisions: [], can_appeal?: false, appeal_form: nil)}

      override ->
        revisions = Contributions.list_revisions(override.id)
        can_appeal? = can_appeal?(override, revisions, socket.assigns.current_scope.user)

        {:noreply,
         socket
         |> assign(:override, override)
         |> assign(:revisions, revisions)
         |> assign(:can_appeal?, can_appeal?)
         |> assign(:appeal_form, to_form(%{"text" => ""}, as: "appeal"))}
    end
  end

  defp can_appeal?(_override, _revisions, nil), do: false

  defp can_appeal?(override, revisions, user) do
    override.status == :rejected and override.author_id == user.id and
      not Enum.any?(revisions, &(&1.action == :appealed))
  end

  @impl true
  def handle_event("submit_appeal", %{"appeal" => %{"text" => text}}, socket) do
    author = socket.assigns.current_scope.user
    override = socket.assigns.override

    case Contributions.appeal_override(override.id, author, text) do
      {:ok, updated} ->
        revisions = Contributions.list_revisions(updated.id)

        {:noreply,
         socket
         |> assign(:override, updated)
         |> assign(:revisions, revisions)
         |> assign(:can_appeal?, false)
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
        <p class="text-text-muted">{gettext("Statut :")} {@override.status}</p>
        <p class="mt-2 text-text">
          <span class="font-semibold">{gettext("Source :")}</span> {@override.source}
        </p>

        <h2 class="mt-4 text-lg font-semibold text-text">{gettext("Historique")}</h2>
        <ul class="mt-2 space-y-2">
          <li :for={revision <- @revisions} class="rounded border border-border p-2 text-sm">
            <p class="font-semibold text-text">{revision.action}</p>
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
end
