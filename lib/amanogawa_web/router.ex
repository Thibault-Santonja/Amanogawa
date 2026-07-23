defmodule AmanogawaWeb.Router do
  use AmanogawaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AmanogawaWeb.Layouts, :root}
    plug :protect_from_forgery
    # Static fallback so the CSP header is never absent; immediately replaced
    # by the ContentSecurityPolicy plug, which adds the runtime origins.
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug AmanogawaWeb.Plugs.ContentSecurityPolicy
  end

  # Public JSON endpoints consumed by the map/timeline hooks (ADR 0005, ADR
  # 0007): read-only, no session, rate limited per IP.
  pipeline :api do
    plug :accepts, ["json"]
    plug AmanogawaWeb.Plugs.RateLimit
  end

  scope "/", AmanogawaWeb do
    pipe_through :browser

    live "/", ExploreLive
  end

  scope "/api", AmanogawaWeb.Controllers.Api do
    pipe_through :api

    get "/events", EventController, :index
    get "/events/:qid/summary", EventController, :summary
    get "/events/:qid/links", EventController, :links
  end
end
