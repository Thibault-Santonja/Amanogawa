defmodule AmanogawaWeb.SessionHTML do
  @moduledoc """
  Templates for `AmanogawaWeb.SessionController` (issue #032): the magic
  link confirmation page.
  """

  use AmanogawaWeb, :html

  embed_templates "session_html/*"
end
