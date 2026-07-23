defmodule AmanogawaWeb.Router do
  use AmanogawaWeb, :router

  # Strict CSP (project rule: no third-party scripts, all assets self-hosted).
  # `connect-src 'self'` covers the LiveView websocket on the same origin.
  @content_security_policy "default-src 'self'; " <>
                             "img-src 'self' data:; " <>
                             "connect-src 'self'; " <>
                             "object-src 'none'; " <>
                             "base-uri 'self'; " <>
                             "frame-ancestors 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AmanogawaWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => @content_security_policy
    }
  end

  scope "/", AmanogawaWeb do
    pipe_through :browser

    get "/", PageController, :home
  end
end
