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

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :amanogawa, AmanogawaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "75KVMKPkb2FHWwQuCH71XEvNCy2jXAfyF2YeR4dOYKfM4c3nb0OnPL10ZD2bsHDO",
  server: false

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
