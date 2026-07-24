defmodule AmanogawaWeb.FeatureCase do
  @moduledoc """
  Case template for the browser-driven E2E suite (issue #029): a real,
  headless Chrome instance, controlled through Wallaby/chromedriver,
  exercising the map/LiveView hook contracts that `Phoenix.LiveViewTest`
  cannot see (WebGL rendering, real DOM/pointer events, `matchMedia`).

  `use Wallaby.Feature` wires the Ecto SQL sandbox (checkout, and
  `{:shared, self()}` mode unless the test is `async: true`) and starts a
  `session` per `feature/3` test, keyed off `config :wallaby, otp_app:
  :amanogawa` (`ecto_repos`, `config/config.exs`). The sandbox metadata it
  builds only reaches the running server through `Phoenix.Ecto.SQL.Sandbox`
  (`lib/amanogawa_web/endpoint.ex`, gated by `config :amanogawa,
  sql_sandbox: true`, test-only) and a real HTTP listener (`config
  :amanogawa, AmanogawaWeb.Endpoint, server: true`, both in
  `config/test.exs`): the disconnected/mocked conn the rest of the suite
  uses cannot be driven by an actual browser.

  The `:wallaby` OTP application itself (`start/2` shells out to
  `chromedriver --version`/`chrome --version` to validate the pair,
  `Wallaby.Chrome.validate/0`) is started here, in `setup_all`, not by
  `mix test`'s normal app boot: the dependency is declared `runtime:
  false` in `mix.exs` precisely so that never happens automatically, and
  this module is the only place under this suite's control that ever
  calls `Application.ensure_all_started(:wallaby)`. A plain `mix test`
  (default, `:e2e` excluded, `test/test_helper.exs`) never reaches this
  module at all, so it never needs Chrome or chromedriver installed.

  Every test using this case is tagged `:e2e`, excluded from the default
  `mix test` (`test/test_helper.exs`) and run only through `mix test.e2e`
  (`mix.exs`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use Wallaby.Feature

      alias Amanogawa.AtlasFixtures

      @moduletag :e2e

      setup_all do
        AmanogawaWeb.FeatureCase.start_wallaby_and_raise_test_only_rate_limits()
      end
    end
  end

  @doc """
  Starts the `:wallaby` OTP application (see the moduledoc: never a side
  effect of plain `mix test`) and raises, for the lifetime of the current
  `mix test.e2e` process, the two request quotas a real browser would
  otherwise blow through in a single short run: `AmanogawaWeb.RateLimit`
  (the public `/api/events*` JSON endpoints the map/timeline hooks poll on
  every viewport move, style reload, and drag) and `AmanogawaWeb.
  ExploreLive`'s own `select_event` quota. Both are configured
  deliberately tiny in `config/test.exs` (`limit: 5`/`selection_rate_
  limit: 3`) so their OWN dedicated `LiveViewTest`/`ConnTest` throttle
  tests can reach `429`/"selection ignored" in a handful of requests from
  the shared default loopback peer; a real Chrome session, driving the
  actual app, refetches far more than that across even a couple of E2E
  scenarios.

  Also switches `:magic_link_notifier` (issue #032,
  `test/e2e/auth_journey_test.exs`) from the Mox mock plain `mix test`
  uses (`config/test.exs`) to the real `Amanogawa.Accounts.
  MagicLinkNotifier.Mailer`: a real browser drives the actual sign-in
  form, so the magic link must actually reach `Amanogawa.Mailer`
  (`Swoosh.Adapters.Test`, `config :amanogawa, Amanogawa.Mailer` in
  `config/test.exs`) for the auth journey to read it back
  (`share_swoosh_mailbox/0`), the same "test-only env, BEAM separate from
  plain `mix test`" reasoning as the rate limits above.

  `mix test.e2e` runs the E2E suite as a fully separate OS process (a
  distinct BEAM instance) from plain `mix test`, so mutating these
  `Application` env values here can never leak into, or be affected by,
  `AmanogawaWeb.ExploreLiveTest`, `EventControllerTest`, or `Amanogawa.
  AccountsTest`'s own runs.
  """
  @spec start_wallaby_and_raise_test_only_rate_limits() :: :ok
  def start_wallaby_and_raise_test_only_rate_limits do
    {:ok, _apps} = Application.ensure_all_started(:wallaby)

    # Every scenario visits relative paths; Wallaby resolves them against
    # :base_url, which nothing else sets. The endpoint runs a real HTTP
    # listener in this env (server: true, config/test.exs), so its url/0
    # is the single source of truth for host and port.
    Application.put_env(:wallaby, :base_url, AmanogawaWeb.Endpoint.url())

    Application.put_env(:amanogawa, AmanogawaWeb.RateLimit,
      limit: 10_000,
      scale_ms: :timer.hours(24)
    )

    Application.put_env(:amanogawa, AmanogawaWeb.ExploreLive,
      selection_rate_limit: 10_000,
      selection_rate_limit_scale_ms: :timer.minutes(1)
    )

    # Every E2E scenario that signs in shares the same real Chrome peer
    # (127.0.0.1): raised for the same reason as the two quotas above,
    # so the auth journey (issue #032) is never denied by a quota meant
    # to protect a real deployment, not a test run driving one client.
    Application.put_env(:amanogawa, Amanogawa.Accounts.MagicLinkThrottle,
      limit: 10_000,
      scale_ms: :timer.hours(24)
    )

    Application.put_env(
      :amanogawa,
      :magic_link_notifier,
      Amanogawa.Accounts.MagicLinkNotifier.Mailer
    )

    :ok
  end

  @doc """
  Routes every email `Amanogawa.Mailer` (`Swoosh.Adapters.Test`) sends
  for the rest of the calling test to the calling process's own mailbox
  (`Application.put_env(:swoosh, :shared_test_process, self())`), so
  `Swoosh.TestAssertions.assert_email_sent/1` can capture it even though
  the actual delivery runs in the endpoint's request-handling process
  (the browser triggers it, not the test process itself), not the test
  process. Called from a per-test `setup` (never `setup_all`, unlike
  `start_wallaby_and_raise_test_only_rate_limits/0` above): `self()` here
  must be the exact process each `feature/3` block runs in, which
  `setup_all`'s own dedicated case process is not.
  """
  @spec share_swoosh_mailbox() :: :ok
  def share_swoosh_mailbox do
    Application.put_env(:swoosh, :shared_test_process, self())
    :ok
  end
end
