defmodule AmanogawaWeb.E2E.StaticPagesTest do
  @moduledoc """
  Navigation from the map to the static pages (issue #027): a visitor on
  `/` reaches the Sources page through the legal footer overlay, in a real
  browser. The content of the pages themselves is covered exhaustively by
  `AmanogawaWeb.PageControllerTest`; this scenario locks the one thing a
  conn test cannot see: the footer link is actually present, visible, and
  clickable on top of the full-screen map layout.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Wallaby.Query

  feature "from /, clicking Sources in the footer reaches the Sources page", %{session: session} do
    session
    |> visit("/")
    |> wait_for_map_ready()
    # The footer's link specifically, not the topbar's (both point to
    # /sources; an unscoped text query would be ambiguous).
    |> click(Query.css("#legal-footer a[href='/sources']"))
    |> assert_has(Query.css("h1", text: "Sources et à propos"))
    |> assert_has(Query.css("main", text: "Wikidata"))

    assert current_url(session) =~ "/sources"
  end
end
