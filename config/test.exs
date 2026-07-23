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
# so tests never race a background poller.
config :amanogawa, Oban, testing: :manual

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
