# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :amanogawa,
  ecto_repos: [Amanogawa.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Use the custom Postgrex type module so PostGIS geometries map to Geo structs
config :amanogawa, Amanogawa.Repo, types: Amanogawa.PostgresTypes

# SPARQL client used by the ingestion pipelines (Amanogawa.Ingestion.SparqlClient
# port). Overridden with a Mox mock in config/test.exs.
config :amanogawa, :sparql_client, Amanogawa.Ingestion.SparqlClient.QLever

# QLever adapter configuration (ADR 0003): connection/receive timeouts and the
# base backoff delay on HTTP 429 before honoring a Retry-After header.
config :amanogawa, Amanogawa.Ingestion.SparqlClient.QLever,
  base_url: "https://qlever.dev/api/wikidata",
  connect_timeout: :timer.seconds(15),
  receive_timeout: :timer.seconds(120),
  backoff_base_ms: 500,
  retry_after_unit_ms: 1000

# Wikipedia REST client used by the summaries enrichment pipeline
# (Amanogawa.Ingestion.WikipediaClient port). Overridden with a Mox mock in
# config/test.exs.
config :amanogawa, :wikipedia_client, Amanogawa.Ingestion.WikipediaClient.Rest

# Wikipedia REST adapter configuration (ADR 0003): connection/receive
# timeouts and the base backoff delay on HTTP 429 before honoring a
# Retry-After header (mirrors the QLever adapter above).
config :amanogawa, Amanogawa.Ingestion.WikipediaClient.Rest,
  connect_timeout: :timer.seconds(10),
  receive_timeout: :timer.seconds(30),
  backoff_base_ms: 500,
  retry_after_unit_ms: 1000

# Cache freshness window for Wikipedia summaries (ADR 0003): a summary is
# never re-fetched before this many days have passed since its last fetch
# attempt (successful or not, see Amanogawa.Atlas.mark_summary_attempt/1).
config :amanogawa, :summary_max_age_days, 30

# Batch size and inter-batch delay for the summaries enrichment pipeline
# (batch lent, .claude/rules/ethics.md): each job enriches a small batch,
# then schedules its successor after this delay to smooth the load instead
# of hammering the Wikipedia REST API back to back.
config :amanogawa, Amanogawa.Ingestion.Workers.EnrichSummaries,
  batch_size: 50,
  inter_batch_delay_seconds: 30

# Background jobs (ingestion pipelines): a single :ingestion queue at
# concurrency 1 enforces the "one SPARQL query at a time" etiquette rule
# (.claude/rules/ethics.md); :wikipedia likewise enforces "one Wikipedia
# request at a time". Transient backoff is handled by each adapter itself,
# durable resume by the sync_run cursor/selection.
#
# Monthly ingestion sync (ADR 0003, #013), off-peak (UTC), through
# Amanogawa.Ingestion.Workers.ScheduledSync (the only worker Oban.Plugins.
# Cron targets, itself delegating to the Amanogawa.Ingestion facade):
# events first on the 1st, links the next day (needs events populated
# first), summaries the day after (the 30-day extract cache means a
# monthly run only refreshes what expired). Disabled in test
# (config/test.exs): a schedule must never fire during the test suite.
#
# Daily magic link token purge (issue #030), off-peak (UTC), through
# Amanogawa.Accounts.Workers.PurgeExpiredTokens: hygiene only, the
# validity window is enforced in the verification query itself
# (Amanogawa.Accounts.MagicLink), not by this cron.
config :amanogawa, Oban,
  engine: Oban.Engines.Basic,
  repo: Amanogawa.Repo,
  queues: [ingestion: 1, wikipedia: 1, accounts: 1],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 2 1 * *", Amanogawa.Ingestion.Workers.ScheduledSync, args: %{"kind" => "events"}},
       {"0 2 2 * *", Amanogawa.Ingestion.Workers.ScheduledSync, args: %{"kind" => "links"}},
       {"0 2 3 * *", Amanogawa.Ingestion.Workers.ScheduledSync, args: %{"kind" => "summaries"}},
       {"30 3 * * *", Amanogawa.Accounts.Workers.PurgeExpiredTokens}
     ]}
  ]

# Rate limiting for public JSON endpoints (issue #014, `.claude/rules/
# security.md`): Hammer, ETS backend, fixed window, keyed by client IP in
# AmanogawaWeb.Plugs.RateLimit. `:limit` requests are allowed per
# `:scale_ms` window; both are read at request time (not baked into the
# router at compile time), so config/runtime.exs can override the quota per
# environment without a rebuild.
config :amanogawa, AmanogawaWeb.RateLimit,
  limit: 120,
  scale_ms: :timer.minutes(1)

# French is the source and default locale of the user-facing text.
config :amanogawa, AmanogawaWeb.Gettext, default_locale: "fr"

# Alerting (issue #028, option A): sober defaults for
# Amanogawa.Alerting.ErrorReporter, overridable per environment through
# `ALERT_ERROR_THRESHOLD`/`ALERT_WINDOW_MINUTES`/`ALERT_SILENCE_MINUTES`
# (config/runtime.exs, production only). `from`/`recipient` stay nil here
# on purpose: no mail can be sent without both explicitly configured, and
# only production ever sets them.
config :amanogawa, Amanogawa.Alerting,
  threshold: 10,
  window_minutes: 5,
  silence_minutes: 60,
  from: nil,
  recipient: nil

# Swoosh mailer (issue #028): no adapter needs the API HTTP client
# (Amanogawa.Mailer is used by Amanogawa.Alerting.Notifier.Mailer and,
# since issue #031, Amanogawa.Accounts.MagicLinkNotifier.Mailer, through
# Swoosh.Adapters.Local in dev/test or Swoosh.Adapters.SMTP in
# production, config/dev.exs and config/runtime.exs), so this drops the
# Finch dependency Swoosh would otherwise require for API-based adapters
# (SendGrid, Mailgun, ...), which this project never uses.
config :swoosh, :api_client, false

# Magic link sender address (issue #031): reuses ALERT_FROM_EMAIL
# (config/runtime.exs, production only) instead of a second dedicated
# environment variable, both addresses meaning the same thing, "where
# Amanogawa's automated mail comes from" on this host. This documented
# placeholder covers dev/test, where ALERT_FROM_EMAIL is never set and
# Amanogawa.Mailer never actually dials out (Swoosh.Adapters.Local/Test).
config :amanogawa, Amanogawa.Accounts, from: "connexion@amanogawa.example"

# Default outbound port for magic link emails (issue #031): a Mox mock
# in test (config/test.exs), the real Swoosh-backed adapter everywhere
# else. Same pattern as :sparql_client/:wikipedia_client (Ingestion).
config :amanogawa, :magic_link_notifier, Amanogawa.Accounts.MagicLinkNotifier.Mailer

# Magic link double rate limit (issue #031, `.claude/rules/security.md`):
# 5 requests per 15-minute window, per IP and independently per
# normalized email (Amanogawa.Accounts.MagicLinkThrottle), read at call
# time so config/runtime.exs can override the quota
# (MAGIC_LINK_RATE_LIMIT) per environment without a rebuild.
config :amanogawa, Amanogawa.Accounts.MagicLinkThrottle,
  limit: 5,
  scale_ms: :timer.minutes(15)

# Configure the endpoint
config :amanogawa, AmanogawaWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AmanogawaWeb.ErrorHTML, json: AmanogawaWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Amanogawa.PubSub,
  live_view: [signing_salt: "s6kzTOhM"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  amanogawa: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  amanogawa: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
