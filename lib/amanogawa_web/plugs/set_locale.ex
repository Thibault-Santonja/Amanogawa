defmodule AmanogawaWeb.Plugs.SetLocale do
  @moduledoc """
  Resolves the Gettext locale for the current request from a `locale`
  query parameter (issue #027, `AmanogawaWeb.PageController`: the
  Sources/legal/privacy pages are plain controller actions, so the locale
  cannot ride along a LiveView socket the way the rest of the app might
  one day carry it).

  Falls back to the Gettext backend's own default locale
  (`config :amanogawa, AmanogawaWeb.Gettext, default_locale: "fr"`) for a
  missing or unknown `locale` value: an unrecognized locale is never a
  `500`, it is simply French (edge case required by issue #027).
  """

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    locale = resolve(conn.params["locale"])
    Gettext.put_locale(AmanogawaWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end

  defp resolve(candidate) do
    if candidate in Gettext.known_locales(AmanogawaWeb.Gettext) do
      candidate
    else
      default_locale()
    end
  end

  defp default_locale, do: Gettext.get_locale(AmanogawaWeb.Gettext)
end
