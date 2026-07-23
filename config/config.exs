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
config :amanogawa, Oban,
  engine: Oban.Engines.Basic,
  repo: Amanogawa.Repo,
  queues: [ingestion: 1, wikipedia: 1]

# French is the source and default locale of the user-facing text.
config :amanogawa, AmanogawaWeb.Gettext, default_locale: "fr"

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
