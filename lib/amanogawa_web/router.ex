defmodule AmanogawaWeb.Router do
  use AmanogawaWeb, :router

  import AmanogawaWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug AmanogawaWeb.Plugs.SetLocale
    plug :fetch_session
    # After :fetch_session (issue #032, F07 overview): resolves
    # @current_scope for every request on this pipeline, user possibly
    # nil, never a bare nil assign (AmanogawaWeb.UserAuth). The :api and
    # :health pipelines below never gain this plug: the anonymous JSON
    # endpoints and the liveness probe carry no session and no new cost.
    plug :fetch_current_scope_for_user
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

  # Gates controller-only routes under the authenticated scope (issue
  # #032/#033: GET /compte/export is a plain controller action, never a
  # LiveView, so it needs the conn form of the gate rather than
  # live_session's on_mount hook). Stacked on top of :browser, which has
  # already resolved @current_scope by this point.
  # Named :authenticated, not :require_authenticated_user: Phoenix.Router
  # refuses a pipeline whose name collides with an imported function
  # (AmanogawaWeb.UserAuth.require_authenticated_user/2 above).
  pipeline :authenticated do
    plug :require_authenticated_user
  end

  # Public routes (issue #032): the map stays reachable without any
  # account, LoginLive alongside it under the same live_session since
  # both merely need @current_scope.user, possibly nil (F07 overview:
  # "la lecture reste 100% publique"). Never reuse this live_session name
  # for an authenticated-only route: :require_authenticated_user below is
  # the one live_session name reserved for that (never duplicate a
  # live_session name, F07 overview / issue #032).
  scope "/", AmanogawaWeb do
    pipe_through :browser

    live_session :current_user, on_mount: [{AmanogawaWeb.UserAuth, :mount_current_scope}] do
      live "/", ExploreLive
      live "/connexion", LoginLive
    end

    get "/connexion/:token", SessionController, :confirm
    post "/connexion/:token", SessionController, :create
    delete "/deconnexion", SessionController, :delete
  end

  # Authenticated-only routes (first introduced by issue #033's /compte;
  # the on_mount hook itself is written and tested in #032). The
  # controller route below reuses the same require_authenticated_user
  # plug (its conn form) rather than the LiveView on_mount, since GET
  # /compte/export is a plain controller action, never a LiveView.
  #
  # The LiveView route stacks BOTH gates: the :authenticated pipeline is
  # what stashes "user_return_to" on the initial anonymous GET (its
  # `maybe_store_return_to`, so logging in comes back to /compte instead
  # of /), the on_mount hook is what re-checks on the websocket join,
  # which never runs the plug pipeline. Neither replaces the other.
  scope "/", AmanogawaWeb do
    pipe_through [:browser, :authenticated]

    live_session :require_authenticated_user,
      on_mount: [{AmanogawaWeb.UserAuth, :require_authenticated_user}] do
      live "/compte", AccountLive
    end
  end

  scope "/", AmanogawaWeb do
    pipe_through [:browser, :authenticated]

    get "/compte/export", AccountController, :export
  end

  # Reviewer-only routes (issue #035: reuses the :authenticated pipeline
  # for the same "user_return_to" reason documented above, layers
  # AmanogawaWeb.UserAuth.require_reviewer/2 on top). :require_reviewer is
  # its own live_session name, never reused for another gate (F07's "never
  # duplicate a live_session name" lesson applies just as much to this
  # newer name as to :require_authenticated_user).
  pipeline :reviewer do
    plug :require_reviewer
  end

  scope "/", AmanogawaWeb do
    pipe_through [:browser, :authenticated, :reviewer]

    live_session :require_reviewer,
      on_mount: [{AmanogawaWeb.UserAuth, :require_reviewer}] do
      live "/relecture/conflits", ConflictsLive
    end
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

  # Local mailbox preview (issue #031): lets a developer see the magic
  # link emails sent through Swoosh.Adapters.Local (config/dev.exs)
  # without a real SMTP relay. `Application.compile_env/3` gates this at
  # compile time (`config :amanogawa, dev_routes: true`, config/dev.exs
  # only), so the route does not even exist in the :test or :prod build.
  if Application.compile_env(:amanogawa, :dev_routes, false) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
