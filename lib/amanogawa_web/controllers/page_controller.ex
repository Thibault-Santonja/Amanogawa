defmodule AmanogawaWeb.PageController do
  use AmanogawaWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
