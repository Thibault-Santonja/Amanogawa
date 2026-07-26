defmodule AmanogawaWeb.Live.ProposalFormComponent do
  @moduledoc """
  The contribution proposal form (issue #036): a `LiveComponent` (isolated
  state justified, `.claude/rules/liveview.md`) opened by `AmanogawaWeb.
  ExploreLive` through a `push_patch` query parameter, so the open/closed
  state survives a refresh.

  Two modes:

    * `{:correction, field}` - corrects `event`'s `field` (one of
      `Amanogawa.Contributions.Override.field_names/0`, or the literal
      `"link"` for a new typed relation from `event`).
    * `:new_event` - proposes a brand new event (`event` is `nil`).

  Nothing is ever applied directly: every submission goes to
  `Amanogawa.Contributions.propose/3` (`Amanogawa.Contributions.
  ProposalThrottle` checked in the DOMAIN, not just here), landing
  `:pending` in the review queue (issue #037). A successful submission
  closes the form itself with `push_patch/2`: unlike `push_navigate/2` and
  `redirect/2` at the ROOT socket, LiveView explicitly propagates a
  component's own `redirected` field up through the diff (`Phoenix.
  LiveView.Channel`), so calling it here, from the component that already
  holds every assign the closing path needs, is the direct and correct
  way, not a workaround. The closing path itself is the `@close_path`
  assign `AmanogawaWeb.ExploreLive` computes from the CURRENT URL state
  (window, camera and selection preserved, quality review m-finding),
  never re-adding `propose_field`/`propose_new_event`: closing keeps the
  visitor exactly where they were.

  First proposal without a public pseudonym (issue #034's `display_name`):
  this component asks for one FIRST, blocking the rest of the form
  (`Amanogawa.Accounts.set_display_name/2`), explaining that it attributes
  every future revision publicly.

  Position picking is a client/server round trip through the shared
  `MapHook` (issue #036): `push_event("enable_position_picking", ...)`
  asks the hook to switch cursor/click mode; the hook's own `pushEvent`
  always targets the LiveView (never this component, hooks are not
  component-scoped in the DOM), so `AmanogawaWeb.ExploreLive` forwards the
  picked coordinate back here with `Phoenix.LiveView.send_update/3`.

  No gamification anywhere in this template (F08 overview's
  anti-dark-patterns): no contribution counter, no progress nudge, a
  single sober confirmation on success.
  """

  use AmanogawaWeb, :live_component

  alias Amanogawa.Accounts
  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias AmanogawaWeb.Params.EventId

  @field_names ~w(label_fr label_en begin_date end_date position)
  @link_types ~w(part_of follows cause effect significant)

  @source_min_length 5
  @source_max_length 1000

  # A function, not a module attribute (i18n review finding): `gettext/1`
  # resolves against the CALLER's locale at runtime, which a value frozen
  # at compile time cannot do.
  defp precision_labels do
    [
      {"0", gettext("Milliard d'années")},
      {"1", gettext("Cent millions d'années")},
      {"2", gettext("Dizaine de millions d'années")},
      {"3", gettext("Million d'années")},
      {"4", gettext("Centaine de milliers d'années")},
      {"5", gettext("Dizaine de milliers d'années")},
      {"6", gettext("Millénaire")},
      {"7", gettext("Siècle")},
      {"8", gettext("Décennie")},
      {"9", gettext("Année")},
      {"10", gettext("Mois")},
      {"11", gettext("Jour")}
    ]
  end

  # ---------------------------------------------------------------------
  # update/2
  # ---------------------------------------------------------------------

  @impl true
  def update(%{picked_position: position}, socket) do
    {:ok, assign(socket, picked_position: position, picking?: false)}
  end

  def update(assigns, socket) do
    {kind, field} = kind_and_field(assigns.mode)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:kind, kind)
     |> assign(:field, field)
     |> assign_new(:local_user, fn -> assigns.current_scope.user end)
     |> assign_new(:picked_position, fn -> nil end)
     |> assign_new(:picking?, fn -> false end)
     |> assign_new(:target_event, fn -> nil end)
     |> assign_new(:error, fn -> nil end)
     |> assign_new(:display_name_form, fn ->
       to_form(%{"display_name" => ""}, as: "display_name")
     end)
     |> assign_new(:form, fn -> to_form(default_params(kind, field), as: "proposal") end)}
  end

  defp kind_and_field({:correction, "link"}), do: {:link, nil}

  defp kind_and_field({:correction, field}) when field in @field_names,
    do: {:field, String.to_existing_atom(field)}

  defp kind_and_field(:new_event), do: {:new_event, nil}

  defp default_params(:field, field) when field in [:label_fr, :label_en] do
    %{"value" => "", "source" => ""}
  end

  defp default_params(:field, field) when field in [:begin_date, :end_date] do
    %{
      "year" => "",
      "month" => "",
      "day" => "",
      "precision" => "9",
      "calendar" => "gregorian",
      "clear" => "false",
      "source" => ""
    }
  end

  defp default_params(:field, :position) do
    %{"source" => ""}
  end

  defp default_params(:link, nil) do
    %{"target_qid" => "", "link_type" => "part_of", "source" => ""}
  end

  defp default_params(:new_event, nil) do
    %{
      "label_fr" => "",
      "label_en" => "",
      "description_fr" => "",
      "description_en" => "",
      "year" => "",
      "month" => "",
      "day" => "",
      "precision" => "9",
      "calendar" => "gregorian",
      "source" => ""
    }
  end

  # ---------------------------------------------------------------------
  # handle_event/3
  # ---------------------------------------------------------------------

  @impl true
  def handle_event("set_display_name", %{"display_name" => %{"display_name" => name}}, socket) do
    case Accounts.set_display_name(socket.assigns.local_user, name) do
      {:ok, user} ->
        {:noreply, assign(socket, local_user: user)}

      {:error, changeset} ->
        {:noreply, assign(socket, :display_name_form, to_form(changeset, as: "display_name"))}
    end
  end

  def handle_event("validate", %{"proposal" => params}, socket) do
    socket = assign(socket, :form, to_form(params, as: "proposal"))
    {:noreply, maybe_resolve_target_event(socket, params)}
  end

  def handle_event("choose_position", _params, socket) do
    {:noreply,
     socket
     |> assign(:picking?, true)
     |> push_event("enable_position_picking", %{})}
  end

  def handle_event("cancel_position_choice", _params, socket) do
    {:noreply,
     socket
     |> assign(picking?: false, picked_position: nil)
     |> push_event("disable_position_picking", %{})}
  end

  # Escape (or the close button) while the map is in position-picking
  # mode only cancels the PICKING, never the whole form (quality review,
  # Escape finding): the server-side `picking?` flag is the guard, so the
  # decision is deterministic whatever the client races. The next
  # cancel, with picking over, closes the form as before.
  def handle_event("cancel", _params, %{assigns: %{picking?: true}} = socket) do
    {:noreply,
     socket
     |> assign(:picking?, false)
     |> push_event("disable_position_picking", %{})}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> push_event("disable_position_picking", %{})
     |> push_patch(to: socket.assigns.close_path)}
  end

  def handle_event("submit", %{"proposal" => params}, socket) do
    attrs = build_attrs(socket.assigns.kind, socket.assigns.field, params, socket.assigns)
    author_id = socket.assigns.local_user.id
    ip = socket.assigns.peer_ip || "unknown"

    case Contributions.propose(attrs, author_id, ip) do
      {:ok, _override} ->
        {:noreply,
         socket
         |> push_event("disable_position_picking", %{})
         |> put_flash(:info, gettext("Proposition envoyée, elle sera relue."))
         |> push_patch(to: socket.assigns.close_path)}

      {:error, :event_not_found} ->
        {:noreply, assign(socket, :error, gettext("Cet événement est introuvable."))}

      {:error, :rate_limited} ->
        {:noreply,
         assign(
           socket,
           :error,
           gettext("Trop de propositions pour le moment, réessayez plus tard.")
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "proposal", action: :validate))}
    end
  end

  defp maybe_resolve_target_event(%{assigns: %{kind: :link}} = socket, params) do
    case Map.get(params, "target_qid") do
      qid when is_binary(qid) and byte_size(qid) > 0 ->
        target = if EventId.valid?(qid), do: Atlas.get_event_by_qid(qid), else: nil
        assign(socket, :target_event, target)

      _other ->
        assign(socket, :target_event, nil)
    end
  end

  defp maybe_resolve_target_event(socket, _params), do: socket

  # ---------------------------------------------------------------------
  # attrs building (server-side validated regardless, but shaped here so
  # `Amanogawa.Contributions.propose/3` receives the payload its
  # changeset expects, `.claude/rules/liveview.md`: never trust a client
  # payload, but a well-shaped one still needs building from flat form
  # params)
  # ---------------------------------------------------------------------

  defp build_attrs(:field, field, params, assigns) when field in [:label_fr, :label_en] do
    %{
      kind: :field,
      event_qid: assigns.event.qid,
      field: field,
      proposed_value: %{"value" => Map.get(params, "value", "")},
      source: Map.get(params, "source", "")
    }
  end

  defp build_attrs(:field, :end_date, %{"clear" => "true"} = params, assigns) do
    %{
      kind: :field,
      event_qid: assigns.event.qid,
      field: :end_date,
      proposed_value: nil,
      source: Map.get(params, "source", "")
    }
  end

  defp build_attrs(:field, field, params, assigns) when field in [:begin_date, :end_date] do
    %{
      kind: :field,
      event_qid: assigns.event.qid,
      field: field,
      proposed_value: date_payload(params),
      source: Map.get(params, "source", "")
    }
  end

  defp build_attrs(:field, :position, params, assigns) do
    %{
      kind: :field,
      event_qid: assigns.event.qid,
      field: :position,
      proposed_value: position_payload(assigns.picked_position) || %{},
      source: Map.get(params, "source", "")
    }
  end

  defp build_attrs(:link, nil, params, assigns) do
    %{
      kind: :link,
      event_qid: assigns.event.qid,
      target_qid: Map.get(params, "target_qid", ""),
      link_type: safe_link_type(Map.get(params, "link_type")),
      source: Map.get(params, "source", "")
    }
  end

  defp build_attrs(:new_event, nil, params, assigns) do
    %{
      kind: :new_event,
      proposed_value: %{
        "label_fr" => blank_to_nil(Map.get(params, "label_fr", "")),
        "label_en" => blank_to_nil(Map.get(params, "label_en", "")),
        "description_fr" => blank_to_nil(Map.get(params, "description_fr", "")),
        "description_en" => blank_to_nil(Map.get(params, "description_en", "")),
        "begin_date" => date_payload(params),
        "position" => position_payload(assigns.picked_position)
      },
      source: Map.get(params, "source", "")
    }
  end

  defp position_payload(nil), do: nil
  defp position_payload(%{lng: lng, lat: lat}), do: %{"lon" => lng, "lat" => lat}

  defp safe_link_type(value) when value in @link_types, do: String.to_existing_atom(value)
  defp safe_link_type(_other), do: nil

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp date_payload(params) do
    %{
      "year" => parse_int(Map.get(params, "year")),
      "month" => parse_int(Map.get(params, "month")),
      "day" => parse_int(Map.get(params, "day")),
      "precision" => parse_int(Map.get(params, "precision")),
      "calendar" => Map.get(params, "calendar")
    }
  end

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp parse_int(value) when is_integer(value), do: value

  # ---------------------------------------------------------------------
  # render/1
  # ---------------------------------------------------------------------

  @impl true
  def render(assigns) do
    assigns = assign_new(assigns, :precision_labels, fn -> precision_labels() end)

    ~H"""
    <div
      id={@id}
      class="absolute inset-y-0 right-0 z-10 w-full max-w-sm overflow-y-auto border-l border-border bg-surface p-4 shadow-lg sm:w-96"
      aria-label={gettext("Proposer une contribution")}
      phx-window-keydown="cancel"
      phx-key="Escape"
      phx-target={@myself}
    >
      <div class="flex items-start justify-between gap-2">
        <h2 class="text-lg font-semibold text-text">{title(@kind, @mode)}</h2>
        <button
          type="button"
          phx-click="cancel"
          phx-target={@myself}
          aria-label={gettext("Fermer")}
          class="shrink-0 text-text-muted hover:text-text"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>

      <.display_name_gate :if={!@local_user.display_name} form={@display_name_form} myself={@myself} />

      <.proposal_body
        :if={@local_user.display_name}
        kind={@kind}
        field={@field}
        form={@form}
        error={@error}
        picking?={@picking?}
        picked_position={@picked_position}
        target_event={@target_event}
        myself={@myself}
        precision_labels={@precision_labels}
      />
    </div>
    """
  end

  defp title(:field, {:correction, field}),
    do: gettext("Corriger : %{field}", field: field_label(field))

  defp title(:link, _mode), do: gettext("Proposer un lien")
  defp title(:new_event, _mode), do: gettext("Proposer un événement")

  defp field_label("label_fr"), do: gettext("libellé (français)")
  defp field_label("label_en"), do: gettext("libellé (anglais)")
  defp field_label("begin_date"), do: gettext("date de début")
  defp field_label("end_date"), do: gettext("date de fin")
  defp field_label("position"), do: gettext("position")
  defp field_label(_other), do: gettext("champ")

  attr :form, :any, required: true
  attr :myself, :any, required: true

  defp display_name_gate(assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-sm text-text-muted">
        {gettext(
          "Avant votre première proposition, choisissez un pseudonyme public : il attribuera vos contributions dans l'historique public, jamais votre adresse email."
        )}
      </p>
      <.form
        for={@form}
        id="display-name-form"
        phx-submit="set_display_name"
        phx-target={@myself}
        class="mt-3"
      >
        <.input field={@form[:display_name]} label={gettext("Pseudonyme public")} required />
        <.button variant="primary" type="submit">{gettext("Enregistrer")}</.button>
      </.form>
    </div>
    """
  end

  attr :kind, :atom, required: true
  attr :field, :atom, default: nil
  attr :form, :any, required: true
  attr :error, :string, default: nil
  attr :picking?, :boolean, default: false
  attr :picked_position, :any, default: nil
  attr :target_event, :any, default: nil
  attr :myself, :any, required: true
  attr :precision_labels, :list, required: true

  defp proposal_body(assigns) do
    ~H"""
    <div class="mt-4">
      <p
        :if={@error}
        class="mb-2 rounded-md border border-danger bg-danger/10 p-2 text-sm text-danger"
      >
        {@error}
      </p>

      <.form
        for={@form}
        id="proposal-form-form"
        phx-change="validate"
        phx-submit="submit"
        phx-target={@myself}
      >
        <.label_fields :if={@kind == :field and @field in [:label_fr, :label_en]} form={@form} />
        <.date_fields
          :if={@kind == :field and @field in [:begin_date, :end_date]}
          form={@form}
          field={@field}
          precision_labels={@precision_labels}
        />
        <.position_fields
          :if={@kind == :field and @field == :position}
          picking?={@picking?}
          picked_position={@picked_position}
          myself={@myself}
        />
        <.link_fields :if={@kind == :link} form={@form} target_event={@target_event} />
        <.new_event_fields
          :if={@kind == :new_event}
          form={@form}
          picking?={@picking?}
          picked_position={@picked_position}
          precision_labels={@precision_labels}
          myself={@myself}
        />

        <.source_field form={@form} />

        <div class="mt-4 flex gap-2">
          <.button variant="primary" type="submit">{gettext("Envoyer la proposition")}</.button>
          <.button type="button" phx-click="cancel" phx-target={@myself}>
            {gettext("Annuler")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  attr :form, :any, required: true

  defp label_fields(assigns) do
    ~H"""
    <.input field={@form[:value]} label={gettext("Nouvelle valeur")} required />
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :precision_labels, :list, required: true

  defp date_fields(assigns) do
    ~H"""
    <div>
      <label :if={@field == :end_date} class="mb-2 flex items-center gap-2 text-sm text-text">
        <input type="hidden" name="proposal[clear]" value="false" />
        <input type="checkbox" name="proposal[clear]" value="true" class="rounded" />
        {gettext("Retirer la date de fin")}
      </label>
      <div class="grid grid-cols-3 gap-2">
        <.input field={@form[:year]} type="number" label={gettext("Année")} />
        <.input field={@form[:month]} type="number" label={gettext("Mois")} />
        <.input field={@form[:day]} type="number" label={gettext("Jour")} />
      </div>
      <label class="mt-2 block text-sm text-text-muted">
        {gettext("Précision")}
        <select
          name="proposal[precision]"
          class="mt-1 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text"
        >
          <option
            :for={{value, label} <- @precision_labels}
            value={value}
            selected={@form[:precision].value == value}
          >
            {label}
          </option>
        </select>
      </label>
      <label class="mt-2 block text-sm text-text-muted">
        {gettext("Calendrier")}
        <select
          name="proposal[calendar]"
          class="mt-1 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text"
        >
          <option value="gregorian" selected={@form[:calendar].value == "gregorian"}>
            {gettext("Grégorien")}
          </option>
          <option value="julian" selected={@form[:calendar].value == "julian"}>
            {gettext("Julien")}
          </option>
        </select>
      </label>
    </div>
    """
  end

  attr :picking?, :boolean, required: true
  attr :picked_position, :any, required: true
  attr :myself, :any, required: true

  defp position_fields(assigns) do
    ~H"""
    <div>
      <p :if={@picked_position} class="text-sm text-text">
        {gettext("Position choisie :")} {Float.round(@picked_position.lat, 5)}, {Float.round(
          @picked_position.lng,
          5
        )}
      </p>
      <p :if={!@picked_position} class="text-sm text-text-muted">
        {gettext("Aucune position choisie.")}
      </p>
      <div class="mt-2 flex gap-2">
        <.button type="button" phx-click="choose_position" phx-target={@myself}>
          {if @picking?, do: gettext("Cliquez sur la carte…"), else: gettext("Choisir sur la carte")}
        </.button>
        <.button
          :if={@picking? || @picked_position}
          type="button"
          phx-click="cancel_position_choice"
          phx-target={@myself}
        >
          {gettext("Effacer")}
        </.button>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :target_event, :any, default: nil

  defp link_fields(assigns) do
    ~H"""
    <div>
      <.input
        field={@form[:target_qid]}
        label={gettext("Identifiant de l'événement cible (QID)")}
        required
      />
      <p class="mt-1 text-sm text-text-muted">
        <%= if @form[:target_qid].value not in [nil, ""] do %>
          <%= if @target_event do %>
            {gettext("Cible :")} {@target_event.label_fr || @target_event.label_en}
          <% else %>
            {gettext("Aucun événement local ne correspond à cet identifiant.")}
          <% end %>
        <% end %>
      </p>
      <label class="mt-2 block text-sm text-text-muted">
        {gettext("Type de lien")}
        <select
          name="proposal[link_type]"
          class="mt-1 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text"
        >
          <option value="part_of" selected={@form[:link_type].value == "part_of"}>
            {gettext("fait partie de")}
          </option>
          <option value="follows" selected={@form[:link_type].value == "follows"}>
            {gettext("suit")}
          </option>
          <option value="cause" selected={@form[:link_type].value == "cause"}>
            {gettext("cause")}
          </option>
          <option value="effect" selected={@form[:link_type].value == "effect"}>
            {gettext("effet")}
          </option>
          <option value="significant" selected={@form[:link_type].value == "significant"}>
            {gettext("événement notable lié")}
          </option>
        </select>
      </label>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :picking?, :boolean, required: true
  attr :picked_position, :any, required: true
  attr :precision_labels, :list, required: true
  attr :myself, :any, required: true

  defp new_event_fields(assigns) do
    ~H"""
    <div>
      <.input field={@form[:label_fr]} label={gettext("Libellé (français)")} />
      <.input field={@form[:label_en]} label={gettext("Libellé (anglais)")} />
      <.input field={@form[:description_fr]} label={gettext("Description (français, optionnel)")} />
      <.input field={@form[:description_en]} label={gettext("Description (anglais, optionnel)")} />
      <.date_fields form={@form} field={:begin_date} precision_labels={@precision_labels} />
      <.position_fields picking?={@picking?} picked_position={@picked_position} myself={@myself} />
    </div>
    """
  end

  attr :form, :any, required: true

  defp source_field(assigns) do
    length = (assigns.form.params["source"] || "") |> String.length()

    assigns =
      assigns
      |> assign(:length, length)
      |> assign(:min, @source_min_length)
      |> assign(:max, @source_max_length)

    ~H"""
    <div class="mt-3">
      <label class="block text-sm text-text-muted">
        {gettext("Justification (source ou référence, %{min}-%{max} caractères)",
          min: @min,
          max: @max
        )}
        <textarea
          name="proposal[source]"
          rows="3"
          class="mt-1 w-full rounded-md border border-border bg-surface px-3 py-2 text-sm text-text"
        >{@form[:source].value}</textarea>
      </label>
      <p class="mt-1 text-xs text-text-muted">{@length}/{@max}</p>
      <p
        :for={msg <- Enum.map(@form[:source].errors, &translate_error/1)}
        class="mt-1 text-sm text-danger"
      >
        {msg}
      </p>
      <%!-- Issue #038: no personal data in a justification (the rule
      published on /moderation and checked at review time), and this
      contribution joins a public, permanent history (the privacy
      policy's own arbitrage, article 17.3.d): both cross-referenced
      here, right where a contributor is about to write one. --%>
      <p class="mt-2 text-xs text-text-muted">
        {gettext("Ne jamais inclure de donnée personnelle dans cette justification.")}
        <.link navigate={~p"/moderation"} class="text-accent hover:underline">
          {gettext("Règles de modération")}
        </.link>
        ·
        <.link navigate={~p"/confidentialite"} class="text-accent hover:underline">
          {gettext("Politique de confidentialité")}
        </.link>
      </p>
    </div>
    """
  end
end
