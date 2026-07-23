ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Amanogawa.Repo, :manual)

# The E2E suite (issue #029, `test/e2e/`, `@moduletag :e2e` via
# `AmanogawaWeb.FeatureCase`) is excluded from the default `mix test`: it
# drives a real, headless Chrome through Wallaby/chromedriver, which is
# slow and requires a browser installed locally. Run explicitly with
# `mix test.e2e` (`mix.exs`'s alias, `--only e2e` overrides this exclusion).
ExUnit.configure(exclude: [:e2e])
