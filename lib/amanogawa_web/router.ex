defmodule AmanogawaWeb.Router do
  use AmanogawaWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug AmanogawaWeb.Plugs.SetLocale
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AmanogawaWeb.Layouts, :root}
    plug :protect_from_forgery
    # Static fallback so the CSP header is never absent; immediately replaced
    # by the ContentSecurityPolicy plug, which adds the runtime origins.
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug AmanogawaWeb.Plugs.ContentSecurityPolicy
  end

  # Static, sessionless pages (issue #027): Sources/About, legal notice,
  # privacy policy. Deliberately without :fetch_session or
  # :protect_from_forgery, unlike :browser above: these pages hold no
  # form and need no CSRF token, and the privacy policy they serve
  # promises zero cookie to an anonymous visitor. Skipping :fetch_session
  # is what makes that true here: Plug.CSRFProtection is what would
  # otherwise write a `_csrf_token` into the session (hence a Set-Cookie
  # header) the moment the root layout's `get_csrf_token()` call runs,
  # even on a plain GET (see the page controller test). Without
  # :protect_from_forgery in this pipeline, the CSRF meta tag the root
  # layout still renders is a harmless, request-scoped value that is
  # never persisted anywhere.
  pipeline :static_page do
    plug :accepts, ["html"]
    plug AmanogawaWeb.Plugs.SetLocale
    plug :put_root_layout, html: {AmanogawaWeb.Layouts, :root}
    plug :put_secure_browser_headers, %{"content-security-policy" => "default-src 'self'"}
    plug AmanogawaWeb.Plugs.ContentSecurityPolicy
  end

  # Public JSON endpoints consumed by the map/timeline hooks (ADR 0005, ADR
  # 0007): read-only, no session, rate limited per IP.
  pipeline :api do
    plug :accepts, ["json"]
    plug AmanogawaWeb.Plugs.RateLimit
  end

  # Liveness probe (issue #026): no session, no CSRF, no rate limiting.
  # kamal-proxy polls this frequently and must never be throttled or asked
  # to carry a session cookie it has no use for.
  pipeline :health do
    plug :accepts, ["json"]
  end

  scope "/", AmanogawaWeb do
    pipe_through :browser

    live "/", ExploreLive
  end

  scope "/", AmanogawaWeb do
    pipe_through :static_page

    get "/sources", PageController, :sources
    get "/mentions-legales", PageController, :legal
    get "/confidentialite", PageController, :privacy
  end

  scope "/", AmanogawaWeb do
    pipe_through :health

    get "/health", HealthController, :check
  end

  scope "/api", AmanogawaWeb.Controllers.Api do
    pipe_through :api

    get "/events", EventController, :index
    get "/events/histogram", EventController, :histogram
    get "/events/:qid/summary", EventController, :summary
    get "/events/:qid/links", EventController, :links
    get "/borders", BorderController, :index
  end
end
