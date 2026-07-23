defmodule Amanogawa.MixProject do
  use Mix.Project

  def project do
    [
      app: :amanogawa,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      test_coverage: [tool: ExCoveralls],
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Amanogawa.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        "test.e2e": :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.9"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:geo_postgis, "~> 3.7"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:req, "~> 0.5"},
      {:oban, "~> 2.19"},
      {:hammer, "~> 7.4"},
      {:remote_ip, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:mox, "~> 1.2", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      # The E2E suite (issue #029, `test/e2e/`): excluded from plain `mix
      # test` (`test/test_helper.exs` excludes the `:e2e` tag by default),
      # run only through this alias, `--only e2e` overriding that default
      # exclusion. Requires Chrome + chromedriver locally; CI runs this as
      # its own step (`.github/workflows/ci.yml`).
      "test.e2e": ["ecto.create --quiet", "ecto.migrate --quiet", "test --only e2e"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd --cd assets npm install --no-fund --no-audit"
      ],
      "assets.build": ["compile", "tailwind amanogawa", "esbuild amanogawa"],
      "assets.deploy": [
        "tailwind amanogawa --minify",
        "esbuild amanogawa --minify",
        "phx.digest"
      ],
      # Contractual order (fail fast): compile, format, static analysis,
      # asset build (needs `mix assets.setup` once), JS unit tests, then
      # the Elixir test suite.
      # Mirrored exactly by CI (.github/workflows/ci.yml); keep them in sync.
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        # `--skip` honors inline `# sobelow_skip [...]` annotations (issue
        # #023: `Amanogawa.Ingestion.Borders.GeojsonStream.features/2`
        # reads an operator-supplied local mix task path, not web input;
        # Sobelow's static Traversal.FileModule check cannot tell the two
        # apart).
        "sobelow --exit --skip",
        "assets.build",
        "cmd --cd assets npm test",
        "test"
      ]
    ]
  end
end
