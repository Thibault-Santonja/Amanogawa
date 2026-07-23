import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :amanogawa, Amanogawa.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database: "amanogawa_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# A real HTTP listener is required for the E2E suite (issue #029): Chrome,
# driven through Wallaby/chromedriver, is an actual browser process that
# connects over the network, unlike `Phoenix.ConnTest`'s in-process conn.
# Harmless for the rest of the suite (`Phoenix.LiveViewTest`/`ConnTest`
# never dial out to it), and is the standard shape for a Phoenix app that
# ships a Wallaby suite.
config :amanogawa, AmanogawaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "75KVMKPkb2FHWwQuCH71XEvNCy2jXAfyF2YeR4dOYKfM4c3nb0OnPL10ZD2bsHDO",
  server: true

# Mounts `Phoenix.Ecto.SQL.Sandbox` on the endpoint (`lib/amanogawa_web/
# endpoint.ex`): the plug that lets a real browser's HTTP requests (E2E
# suite, issue #029) reach the same sandboxed DB connection/transaction the
# test process checked out, through a header the browser session carries.
# Compile-time (`Application.compile_env/3`), not a runtime config read, so
# the plug is simply absent from the pipeline the app compiles for `:dev`/
# `:prod`.
config :amanogawa, sql_sandbox: true

# Renders `data-e2e-test-api="true"` on `#map` (`AmanogawaWeb.ExploreLive`)
# so `assets/js/hooks/map_hook.js` wires `window.__amanogawaE2E__` (issue
# #029's own "témoin de test minimal sur window, uniquement en
# environnement test, documenté"): a way for the E2E suite to trigger the
# exact `select_event`/`deselect_event` intent a real marker click sends,
# without depending on WebGL canvas hit-testing under headless Chrome for
# every scenario that only cares about the LiveView/URL/panel contract.
# `false` by default (`AmanogawaWeb.ExploreLive`'s own fallback): only this
# file ever flips it on, so the branch is dead code in `:dev`/`:prod`.
config :amanogawa, :expose_e2e_test_api, true

# Wallaby (issue #029): drives a real, headless Chrome through chromedriver
# for the `:e2e`-tagged suite (`mix test.e2e`, excluded from plain `mix
# test`, see `test/test_helper.exs`). `otp_app` is what lets `Wallaby.
# Feature`'s own setup find `Amanogawa.Repo` (`config :amanogawa,
# ecto_repos`) and check it out into the SQL sandbox per test.
#
# The `:wallaby` OTP application is never started as a side effect of
# `mix test`/`mix precommit`: the dependency is declared `runtime: false`
# in `mix.exs`, so it is compiled and available, but its own `start/2`
# (which shells out to `chromedriver --version`/`chrome --version` to
# validate the pair, `Wallaby.Chrome.validate/0`) only runs when
# `test/support/feature_case.ex` explicitly starts it, which itself only
# happens for the `:e2e`-tagged tests `mix test.e2e` opts into. A developer
# who never runs `mix test.e2e` never needs Chrome or chromedriver
# installed at all.
config :wallaby,
  otp_app: :amanogawa,
  screenshot_on_failure: true,
  chromedriver: [
    # `headless: true` would append Chrome's LEGACY `--headless` flag
    # (wallaby appends the bare flag), whose rendering stack cannot create
    # a software WebGL context. The modern mode is opted into explicitly
    # through `--headless=new` in the args below instead.
    headless: false,
    capabilities: %{
      javascriptEnabled: true,
      loadImages: true,
      version: "",
      rotatable: false,
      takesScreenshot: true,
      cssSelectorsEnabled: true,
      nativeEvents: false,
      platform: "ANY",
      unhandledPromptBehavior: "accept",
      loggingPrefs: %{browser: "DEBUG"},
      chromeOptions: %{
        args: [
          # Modern headless mode: unlike the legacy `--headless` (which
          # wallaby's `headless: true` would append), it shares the regular
          # browser's rendering stack and supports software WebGL.
          "--headless=new",
          # `--no-sandbox`: chromedriver commonly runs as root in a CI
          # container, where Chrome's own sandbox refuses to start at all.
          "--no-sandbox",
          # CI containers routinely mount a tiny `/dev/shm`; Chrome falls
          # back to disk-backed shared memory instead of crashing on it.
          "--disable-dev-shm-usage",
          "--window-size=1400,1000",
          # Software WebGL fallback: CI's runner has no GPU, and MapLibre
          # GL JS (`assets/js/hooks/map_hook.js`) refuses to construct a
          # `maplibregl.Map` at all without a working WebGL context.
          # `--use-gl=swiftshader` forces Chrome's software rasterizer
          # instead of leaving WebGL unavailable the way `--disable-gpu`
          # alone can on a headless, GPU-less host (issue #029's own point
          # d'attention: documented here since this is the one place this
          # tradeoff is made, not a claim that it is guaranteed to work on
          # every Chrome/chromedriver build CI happens to install).
          # Chrome 129+ gates software WebGL behind an explicit opt in:
          # angle routes gl calls to swiftshader, and the unsafe flag
          # re-enables the software fallback that plain
          # `--use-gl=swiftshader` no longer provides.
          "--use-angle=swiftshader",
          "--enable-unsafe-swiftshader",
          "--enable-webgl",
          "--ignore-gpu-blocklist"
        ]
      }
    }
  ]

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Ingestion pipelines depend only on the Amanogawa.Ingestion.SparqlClient
# behaviour; tests stub it with Mox, never hitting a real SPARQL endpoint.
config :amanogawa, :sparql_client, Amanogawa.Ingestion.SparqlClientMock

# The QLever adapter's own tests exercise Req against a Req.Test stub (no
# network) and use a near-zero backoff base and Retry-After unit so
# 429/backoff scenarios run fast instead of actually sleeping for seconds.
config :amanogawa, Amanogawa.Ingestion.SparqlClient.QLever,
  plug: {Req.Test, Amanogawa.Ingestion.SparqlClient.QLever},
  backoff_base_ms: 1,
  retry_after_unit_ms: 1

# Ingestion pipelines depend only on the Amanogawa.Ingestion.WikipediaClient
# behaviour; tests stub it with Mox, never hitting the real Wikipedia REST
# API.
config :amanogawa, :wikipedia_client, Amanogawa.Ingestion.WikipediaClientMock

# The Rest adapter's own tests exercise Req against a Req.Test stub (no
# network) and use a near-zero backoff base and Retry-After unit so
# 429/backoff scenarios run fast instead of actually sleeping for seconds.
config :amanogawa, Amanogawa.Ingestion.WikipediaClient.Rest,
  plug: {Req.Test, Amanogawa.Ingestion.WikipediaClient.Rest},
  backoff_base_ms: 1,
  retry_after_unit_ms: 1

# Oban runs in manual testing mode: jobs are asserted with Oban.Testing
# (enqueued jobs, `perform_job/2`) instead of executing through real queues,
# so tests never race a background poller. `plugins: false` overrides
# config/config.exs's Oban.Plugins.Cron schedule entirely (#013): the
# monthly sync must never fire during the test suite.
config :amanogawa, Oban, testing: :manual, plugins: false

# Tiny pagination plan so tests can exercise several slices and several
# pages per slice against small fixtures instead of the production
# millions-of-QIDs plan.
config :amanogawa, Amanogawa.Ingestion.Workers.ImportEvents,
  page_size: 3,
  slice_width: 10,
  max_qid: 20

# Tiny batch size and no inter-batch delay so summaries enrichment tests
# exercise several batches against small fixtures without actually
# scheduling/waiting on Oban's `schedule_in`.
config :amanogawa, Amanogawa.Ingestion.Workers.EnrichSummaries,
  batch_size: 2,
  inter_batch_delay_seconds: 0

# Tiny pagination plan (same shape as ImportEvents above) so relation
# import tests exercise several slices and several pages per slice against
# small fixtures instead of the production millions-of-QIDs plan.
config :amanogawa, Amanogawa.Ingestion.Workers.ImportLinks,
  page_size: 3,
  slice_width: 10,
  max_qid: 20

# Small quota so AmanogawaWeb.Controllers.Api.EventControllerTest can reach
# the 429 path in a handful of requests. Every other conn test that hits
# /api/events uses its own fake remote IP (distinct rate-limit bucket), so
# this low quota never bleeds into unrelated tests.
#
# scale_ms is 24h, not 1 minute: Hammer's fixed-window algorithm buckets
# hits into `div(now, scale_ms)` slices aligned on the wall clock (see
# `deps/hammer/lib/hammer/ets/fix_window.ex`), not a window that starts
# counting from the first hit. With a 1-minute scale, a wall-clock minute
# boundary crossed mid-test (between any of the 6 requests fired in a tight
# loop) silently resets the counter, so fewer than 6 hits land in the same
# window and the test never reaches its expected 429 (flaky, reproduced by
# running the suite at HH:MM:59.9). A 24h window makes that boundary
# practically unreachable within a single test run, while every other test
# hitting /api/events still uses its own fake remote IP (a distinct
# Hammer key), so this generous window causes no cross-test bleed.
config :amanogawa, AmanogawaWeb.RateLimit,
  limit: 5,
  scale_ms: :timer.hours(24)

# Small, dedicated quota so AmanogawaWeb.ExploreLiveTest can reach the
# "throttled, selection ignored" path in a handful of hits. Every other
# test invoking select_event uses the LiveView's default connect_info peer
# (127.0.0.1) at most once or twice, far under this quota; the tests that
# specifically exercise it set their own unique remote_ip on the test conn
# (mirrors event_controller_test.exs's unique_ip pattern), so this low
# quota never bleeds into unrelated tests.
config :amanogawa, AmanogawaWeb.ExploreLive,
  selection_rate_limit: 3,
  selection_rate_limit_scale_ms: :timer.minutes(1)
