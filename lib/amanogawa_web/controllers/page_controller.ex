defmodule AmanogawaWeb.PageController do
  @moduledoc """
  Static, sessionless pages (issue #027): Sources/About, legal notice,
  privacy policy. No LiveView, no form, no database query: plain
  server-rendered HTML through `AmanogawaWeb.PageHTML`, on the
  `:static_page` router pipeline (`AmanogawaWeb.Router`), which carries
  neither `:fetch_session` nor `:protect_from_forgery`.
  """

  use AmanogawaWeb, :controller

  alias Amanogawa.Contributions

  @doc "Renders `/sources`: source attributions, licenses, and the About page."
  @spec sources(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def sources(conn, _params) do
    render(conn, :sources, page_title: gettext("Sources et à propos"))
  end

  @doc "Renders `/mentions-legales`."
  @spec legal(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def legal(conn, _params) do
    render(conn, :legal, page_title: gettext("Mentions légales"))
  end

  @doc "Renders `/confidentialite`."
  @spec privacy(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def privacy(conn, _params) do
    render(conn, :privacy, page_title: gettext("Politique de confidentialité"))
  end

  @doc """
  Renders `/moderation` (issue #038): the published moderation rules and
  `Amanogawa.Contributions.public_stats/0`'s factual, aggregate
  statistics (totals by status, proposals per month, median decision
  delay, open sync conflicts). No contributor ranking, no "top", no
  series meant to drive engagement (F08 overview's anti-dark-patterns
  principle): every number here describes the PROCESS, never a person.
  """
  @spec moderation(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def moderation(conn, _params) do
    render(conn, :moderation,
      page_title: gettext("Modération"),
      stats: Contributions.public_stats()
    )
  end
end
