import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/amanogawa start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :amanogawa, AmanogawaWeb.Endpoint, server: true
end

config :amanogawa, AmanogawaWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# List of trusted reverse-proxy IPs/CIDRs the `RemoteIp` plug
# (`AmanogawaWeb.Endpoint`) trusts to set `X-Forwarded-For`/`Forwarded`
# headers (issue security-review #4). Read in every environment, not just
# :prod: empty by default (`TRUSTED_PROXIES` unset), which is a no-op and
# keeps dev/test behavior unchanged (no test ever sends a forwarding
# header, so this never fires there regardless). Only set `TRUSTED_PROXIES`
# on a deployment that actually sits behind a reverse proxy/load balancer;
# setting it without one would let any direct client spoof its own IP.
trusted_proxies = System.get_env("TRUSTED_PROXIES", "") |> String.split(",", trim: true)
config :amanogawa, :trusted_proxies, trusted_proxies

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :amanogawa, AmanogawaWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/amanogawa_web/router\.ex$"E,
        ~r"lib/amanogawa_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :amanogawa, Amanogawa.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname of the application.
      """

  config :amanogawa, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Public JSON endpoint rate limit (issue #014): overridable per deployment
  # without a rebuild, since AmanogawaWeb.Plugs.RateLimit reads this config
  # at request time rather than at router compile time. Window stays fixed
  # at one minute; only the quota is meant to be tuned per environment.
  config :amanogawa, AmanogawaWeb.RateLimit,
    limit: String.to_integer(System.get_env("RATE_LIMIT_PER_MINUTE", "120")),
    scale_ms: :timer.minutes(1)

  config :amanogawa, AmanogawaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Structured JSON logs (issue #028): production only, development keeps
  # the human-readable template format unchanged (config/dev.exs). Every
  # metadata key Logger holds is forwarded to the formatter
  # (`Amanogawa.Logging.JSONFormatter` sanitizes anything it cannot
  # serialize, never crashes), unlike the narrower `[:request_id]` list
  # used by the default formatter elsewhere (config/config.exs): a
  # production incident benefits from more context (module, function,
  # line, crash_reason on exception logs), not less.
  config :logger, :default_formatter,
    format: {Amanogawa.Logging.JSONFormatter, :format},
    metadata: :all

  # Alerting (issue #028, option A): sober thresholds, overridable without
  # a rebuild. No mail is ever sent unless ALERT_RECIPIENT_EMAIL is set:
  # a deployment that never configures it simply runs without alerting
  # rather than crashing at boot (self-hosting a minimal setup, ADR 0008,
  # must not require SMTP just to start).
  config :amanogawa, Amanogawa.Alerting,
    threshold: String.to_integer(System.get_env("ALERT_ERROR_THRESHOLD", "10")),
    window_minutes: String.to_integer(System.get_env("ALERT_WINDOW_MINUTES", "5")),
    silence_minutes: String.to_integer(System.get_env("ALERT_SILENCE_MINUTES", "60")),
    from: System.get_env("ALERT_FROM_EMAIL"),
    recipient: System.get_env("ALERT_RECIPIENT_EMAIL")

  # Local SMTP relay (issue #028): the same relay already used by the
  # other projects on this VPS (msmtp or equivalent, `.claude/memory/
  # tech-stack.md`), never a third-party transactional email provider.
  # No authentication by default (`SMTP_USERNAME` unset): a relay bound to
  # localhost typically needs none.
  config :amanogawa, Amanogawa.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.get_env("SMTP_RELAY_HOST", "localhost"),
    port: String.to_integer(System.get_env("SMTP_RELAY_PORT", "25")),
    username: System.get_env("SMTP_USERNAME"),
    password: System.get_env("SMTP_PASSWORD"),
    ssl: System.get_env("SMTP_SSL") in ~w(true 1),
    tls: :if_available,
    auth: if(System.get_env("SMTP_USERNAME"), do: :always, else: :never)

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :amanogawa, AmanogawaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :amanogawa, AmanogawaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
