defmodule AmanogawaWeb.LoginLive do
  @moduledoc """
  `/connexion` (issue #032): a single email form, no distinction between
  sign-up and sign-in (F07 overview / issue #030: the flow is identical
  for a known or unknown email, anti-enumeration). Submitting always
  lands on the exact same "check your inbox" state, whether or not the
  address has an account, unless the request was rate limited or the
  email itself is malformed.

  Already-authenticated visitors are redirected to `/` in `mount/3`:
  pure branching on the scope assigned by the `:current_user` on_mount
  hook, no database access (`.claude/rules/liveview.md`).
  """

  use AmanogawaWeb, :live_view

  alias Amanogawa.Accounts
  alias AmanogawaWeb.ClientIp

  @impl true
  def mount(params, _session, socket) do
    if socket.assigns.current_scope.user do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      locale = resolve_locale(params["locale"])
      Gettext.put_locale(AmanogawaWeb.Gettext, locale)

      # `AmanogawaWeb.ClientIp.peer_ip/1`: `nil` on a disconnected/mocked
      # socket (no real client to throttle), the resolved client address
      # otherwise (forwarding headers unwound against the trusted proxy
      # list, peer fallback: behind a reverse proxy the raw peer would be
      # the proxy itself, one shared throttle bucket for everyone).
      {:ok,
       socket
       |> assign(:page_title, gettext("Connexion"))
       |> assign(:peer_ip, ClientIp.peer_ip(socket))
       |> assign(:locale, locale)
       |> assign(:sent?, false)
       |> assign(:form, to_form(%{"email" => ""}, as: "login"))}
    end
  end

  # The `/connexion` route's own `?locale=` query param, present on both
  # the static and the connected mount (LiveView re-parses the browser's
  # current URL on reconnect): the LiveView process itself starts with
  # the Gettext backend's default locale rather than inheriting the
  # plug's (`AmanogawaWeb.Plugs.SetLocale` runs in a different process
  # for a connected mount), so `mount/3` above applies this resolved
  # value explicitly (`Gettext.put_locale/2`) before rendering or
  # delivering the magic link email, and it is also what the magic link
  # URL built below carries forward for the eventual click. Same
  # known-locale allowlist as `SetLocale`, same fallback.
  defp resolve_locale(candidate) do
    if candidate in Gettext.known_locales(AmanogawaWeb.Gettext) do
      candidate
    else
      Gettext.get_locale(AmanogawaWeb.Gettext)
    end
  end

  @impl true
  def handle_event("send_magic_link", %{"login" => %{"email" => email}}, socket) do
    magic_link_url_fun = fn token ->
      url(~p"/connexion/#{token}") <> "?locale=" <> socket.assigns.locale
    end

    case deliver(socket, email, magic_link_url_fun) do
      :ok ->
        {:noreply, assign(socket, sent?: true, form: to_form(%{"email" => email}, as: "login"))}

      {:error, :rate_limited} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           gettext("Trop de demandes, réessayez dans quelques minutes.")
         )
         |> assign(:form, to_form(%{"email" => email}, as: "login"))}

      {:error, changeset} ->
        form = changeset |> Map.put(:action, :validate) |> to_form(as: "login")
        {:noreply, assign(socket, :form, form)}
    end
  end

  defp deliver(%{assigns: %{peer_ip: nil, locale: locale}}, email, magic_link_url_fun) do
    Accounts.deliver_magic_link(email, "unknown", locale, magic_link_url_fun)
  end

  defp deliver(%{assigns: %{peer_ip: peer_ip, locale: locale}}, email, magic_link_url_fun) do
    ip = peer_ip |> :inet.ntoa() |> to_string()
    Accounts.deliver_magic_link(email, ip, locale, magic_link_url_fun)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.page page_title={@page_title} current_scope={@current_scope} flash={@flash}>
      <div :if={@sent?} id="magic-link-sent" class="rounded-md border border-border bg-surface p-4">
        <p class="text-text">
          {gettext(
            "Vérifiez votre boîte mail : si cette adresse est associée à un compte (ou peut en créer un), un lien de connexion valable 15 minutes vient de vous être envoyé."
          )}
        </p>
      </div>

      <.form
        :if={!@sent?}
        for={@form}
        id="login-form"
        phx-submit="send_magic_link"
        class="mt-4 max-w-sm"
      >
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Adresse email")}
          required
          autocomplete="email"
        />
        <.button variant="primary">
          {gettext("Recevoir un lien de connexion")}
        </.button>
      </.form>
    </Layouts.page>
    """
  end
end
