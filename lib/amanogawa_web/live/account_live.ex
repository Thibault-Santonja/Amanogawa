defmodule AmanogawaWeb.AccountLive do
  @moduledoc """
  `/compte` (issue #033): the account page. Deliberately minimal, to the
  image of the data it shows (F07 overview / ADR 0008): email, creation
  date, active sessions with per-session and bulk revocation, a link to
  the JSON export (`AmanogawaWeb.AccountController.export/2`), and a
  two-step account deletion.

  First route of `live_session :require_authenticated_user`
  (`AmanogawaWeb.Router`, hook written in #032): an anonymous socket
  never reaches `mount/3` here, `AmanogawaWeb.UserAuth.on_mount(:
  require_authenticated_user, ...)` redirects it to `/connexion` first.

  `mount/3` assigns defaults only; sessions are loaded in
  `handle_params/3` (`.claude/rules/liveview.md`, no database query in
  `mount/3`), then held in a stream (`.claude/rules/liveview.md`:
  collections belong in streams, not assigns), never re-fetched by any
  `handle_event` below (each mutates the stream/assign it already holds
  in place instead of reloading from the database).

  Also carries the public pseudonym editor (issue #036,
  `Amanogawa.Accounts.set_display_name/2`): the same field
  `AmanogawaWeb.Live.ProposalFormComponent` requires before a first
  proposal, editable here at any time.

  Deletion anonymizes the account's public contributions BEFORE deleting
  the account itself (issue #038, `Amanogawa.Contributions.
  anonymize_user/1` then `Amanogawa.Accounts.delete_user/1`): see the
  ordering comment on `confirm_delete_account` below for why.
  """

  use AmanogawaWeb, :live_view

  import AmanogawaWeb.PageHTML, only: [section: 1]

  alias Amanogawa.Accounts
  alias Amanogawa.Contributions
  alias AmanogawaWeb.UserAuth

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Mon compte"))
     |> assign(:session_clear_token, session["user_session_token"])
     |> assign(:current_session_id, nil)
     |> assign(:confirm_delete?, false)
     |> assign(:delete_error, nil)
     |> assign(
       :display_name_form,
       to_form(%{"display_name" => socket.assigns.current_scope.user.display_name || ""},
         as: "display_name"
       )
     )
     |> stream(:sessions, [])}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    user = socket.assigns.current_scope.user
    clear_token = socket.assigns.session_clear_token

    rows =
      user
      |> Accounts.list_session_tokens()
      |> Enum.map(&session_row(&1, clear_token))

    current_session_id = rows |> Enum.find(& &1.current?) |> then(&(&1 && &1.id))

    {:noreply,
     socket
     |> assign(:current_session_id, current_session_id)
     |> stream(:sessions, rows, reset: true)}
  end

  defp session_row(session_token, clear_token) do
    %{
      id: session_token.id,
      inserted_at: session_token.inserted_at,
      current?: clear_token != nil && Accounts.current_session_token?(session_token, clear_token)
    }
  end

  @impl true
  def handle_event("revoke_session", %{"id" => id}, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.revoke_session_token(user, id) do
      :ok ->
        # Only broadcast for a DIFFERENT socket than this one: `after_revoke/2`
        # below already takes care of the current session by itself
        # (`push_navigate/2`, a full reload since /compte and / sit in
        # different live_sessions), and racing that against this very
        # socket's own PubSub "disconnect" would let the disconnect land
        # first over the real websocket transport and swallow the
        # navigation instruction, stranding a real browser back on
        # /compte where it just gets bounced to /connexion instead of
        # anonymous / (only reproduces with a real transport, never in
        # LiveViewTest's mocked one, hence an E2E-only finding, issue #033).
        if id != socket.assigns.current_session_id do
          UserAuth.disconnect_session(UserAuth.live_socket_id(id))
        end

        {:noreply, after_revoke(socket, id)}

      {:error, :not_found} ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke_other_sessions", _params, socket) do
    user = socket.assigns.current_scope.user
    current_id = socket.assigns.current_session_id

    socket =
      user
      |> Accounts.list_session_tokens()
      |> Enum.reject(&(&1.id == current_id))
      |> Enum.reduce(socket, fn session_token, acc ->
        case Accounts.revoke_session_token(user, session_token.id) do
          :ok ->
            UserAuth.disconnect_session(UserAuth.live_socket_id(session_token.id))
            stream_delete(acc, :sessions, %{id: session_token.id})

          {:error, :not_found} ->
            acc
        end
      end)

    {:noreply, put_flash(socket, :info, gettext("Les autres sessions ont été révoquées."))}
  end

  def handle_event("set_display_name", %{"display_name" => %{"display_name" => name}}, socket) do
    case Accounts.set_display_name(socket.assigns.current_scope.user, name) do
      {:ok, user} ->
        current_scope = %{socket.assigns.current_scope | user: user}

        {:noreply,
         socket
         |> assign(:current_scope, current_scope)
         |> assign(:display_name_form, to_form(%{"display_name" => name}, as: "display_name"))
         |> put_flash(:info, gettext("Pseudonyme enregistré."))}

      {:error, changeset} ->
        {:noreply, assign(socket, :display_name_form, to_form(changeset, as: "display_name"))}
    end
  end

  def handle_event("toggle_delete_confirmation", _params, socket) do
    {:noreply,
     assign(socket, confirm_delete?: !socket.assigns.confirm_delete?, delete_error: nil)}
  end

  def handle_event("confirm_delete_account", %{"confirmation" => confirmation}, socket) do
    user = socket.assigns.current_scope.user

    # Same normalization the domain applies to every stored email (trim +
    # downcase): the confirmation checks the visitor knows their address,
    # not that they can reproduce its canonical casing.
    if Accounts.normalize_email(confirmation) == user.email do
      current_session_id = socket.assigns.current_session_id

      # Snapshot the user's OTHER active sessions before the delete
      # cascades them away: each gets disconnected below. The current
      # session is deliberately excluded from that broadcast (same
      # reasoning as `handle_event("revoke_session", ...)` above): the
      # `redirect/2` this very socket issues a few lines down is what
      # takes this browser tab back to anonymous, and broadcasting
      # "disconnect" to this socket's own live_socket_id first raced it
      # in a real browser, stranding the tab on the just-deleted /compte
      # instead of following the redirect to / (E2E-only finding, #033).
      other_session_ids =
        user
        |> Accounts.list_session_tokens()
        |> Enum.reject(&(&1.id == current_session_id))
        |> Enum.map(& &1.id)

      # Anonymize BEFORE deleting (issue #038, `Amanogawa.Contributions.
      # anonymize_user/1`'s own moduledoc): two transactions, two
      # contexts, this order on purpose. A crash between the two calls
      # leaves a state that is still safe and still resumable: the
      # user's contributions are already anonymized (public, but no
      # longer attributed) while the account row itself still exists and
      # can simply be deleted again; the reverse order would instead
      # risk an orphaned attribution pointing at an already-deleted
      # account id, which nothing could self-heal automatically.
      :ok = Contributions.anonymize_user(user)
      :ok = Accounts.delete_user(user)

      Enum.each(other_session_ids, fn id ->
        UserAuth.disconnect_session(UserAuth.live_socket_id(id))
      end)

      {:noreply,
       socket
       |> put_flash(:info, gettext("Votre compte a été supprimé."))
       |> redirect(to: ~p"/")}
    else
      {:noreply,
       assign(socket,
         delete_error: gettext("La confirmation ne correspond pas à votre adresse email.")
       )}
    end
  end

  # A session revoked while it was the one rendering this very socket
  # (the "current session" row): equivalent to a logout, per issue #033
  # ("la révocation de la session courante équivaut à une déconnexion").
  # Broadcasting on its own live_socket_id here also disconnects THIS
  # socket, but `push_navigate/2` below is what actually takes the
  # visitor back to `/` without waiting on the round trip.
  defp after_revoke(socket, id) do
    socket = stream_delete(socket, :sessions, %{id: id})

    if id == socket.assigns.current_session_id do
      socket
      |> put_flash(:info, gettext("Vous avez été déconnecté."))
      |> push_navigate(to: ~p"/")
    else
      put_flash(socket, :info, gettext("Session révoquée."))
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <p class="text-text">
        <span class="font-semibold">{gettext("Email :")}</span> {@current_scope.user.email}
      </p>
      <p class="text-text-muted">
        <span class="font-semibold text-text">{gettext("Compte créé le :")}</span>
        <%!-- The strftime pattern itself is a translation (same technique
        as the timeline's axis templates): "23/07/2026" reads as
        month/day to an English speaker, so each locale supplies its own
        date format. --%>
        {Calendar.strftime(@current_scope.user.inserted_at, gettext("%d/%m/%Y"))}
      </p>

      <.section title={gettext("Pseudonyme public")}>
        <p class="text-text-muted">
          {gettext(
            "Ce pseudonyme attribue publiquement vos contributions : jamais votre adresse email."
          )}
        </p>
        <.form
          for={@display_name_form}
          id="display-name-form"
          phx-submit="set_display_name"
          class="mt-2 max-w-sm"
        >
          <.input field={@display_name_form[:display_name]} label={gettext("Pseudonyme")} required />
          <.button variant="primary" type="submit">{gettext("Enregistrer")}</.button>
        </.form>
      </.section>

      <.section title={gettext("Sessions actives")}>
        <ul id="sessions" phx-update="stream" class="space-y-2">
          <li
            :for={{dom_id, row} <- @streams.sessions}
            id={dom_id}
            class="flex items-center justify-between rounded-md border border-border bg-surface p-3"
          >
            <div>
              <span>{Calendar.strftime(row.inserted_at, gettext("%d/%m/%Y %H:%M"))}</span>
              <span
                :if={row.current?}
                class="ml-2 rounded bg-accent/20 px-2 py-0.5 text-xs text-accent"
              >
                {gettext("Session courante")}
              </span>
            </div>
            <.button phx-click="revoke_session" phx-value-id={row.id}>
              {gettext("Révoquer")}
            </.button>
          </li>
        </ul>
        <.button phx-click="revoke_other_sessions" class="mt-3">
          {gettext("Révoquer toutes les autres sessions")}
        </.button>
      </.section>

      <.section title={gettext("Vos données")}>
        <.button href={~p"/compte/export"} download>
          {gettext("Télécharger mes données (JSON)")}
        </.button>
      </.section>

      <.section title={gettext("Supprimer mon compte")}>
        <p class="text-text-muted">
          {gettext(
            "Cette action est irréversible : toutes vos données personnelles sont effacées immédiatement, sans délai de récupération. Vos contributions publiques éventuelles (éditeur collaboratif) restent visibles dans l'historique public, mais deviennent anonymes (\"compte supprimé\") : c'est ce qui garantit la cohérence de l'historique, comme sur un wiki."
          )}
        </p>
        <.button :if={!@confirm_delete?} phx-click="toggle_delete_confirmation" class="mt-2">
          {gettext("Supprimer mon compte")}
        </.button>

        <form
          :if={@confirm_delete?}
          id="delete-account-form"
          phx-submit="confirm_delete_account"
          class="mt-2 max-w-sm"
        >
          <label for="delete-confirmation" class="mb-1 block text-sm text-text-muted">
            {gettext("Pour confirmer, saisissez votre adresse email :")}
          </label>
          <input
            id="delete-confirmation"
            type="email"
            name="confirmation"
            required
            class="w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text"
          />
          <p :if={@delete_error} class="mt-1 text-sm text-danger">{@delete_error}</p>
          <div class="mt-2 flex gap-2">
            <.button variant="primary" type="submit">
              {gettext("Confirmer la suppression")}
            </.button>
            <.button type="button" phx-click="toggle_delete_confirmation">
              {gettext("Annuler")}
            </.button>
          </div>
        </form>
      </.section>
    </Layouts.page>
    """
  end
end
