defmodule Amanogawa.ReleaseTest do
  # `migrate/0` runs `Ecto.Migrator` against the repo outside the SQL
  # sandbox's ownership mechanism: the sandbox is switched to `:auto` for
  # the duration of this module and back to `:manual` afterwards, which is
  # only safe because `async: false` modules run serially, after every
  # async module has finished.
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(Amanogawa.Repo, :auto)
    on_exit(fn -> Sandbox.mode(Amanogawa.Repo, :manual) end)
    :ok
  end

  describe "migrate/0" do
    test "runs to completion against the test database" do
      # The test database is already fully migrated (`mix test` alias runs
      # `ecto.migrate`): this exercises the exact code path the container
      # entrypoint runs on every boot (`rel/overlays/bin/docker-entrypoint`),
      # including `Ecto.Migrator.with_repo/2` against an already-started
      # repo, and proves a no-op migration pass returns cleanly.
      assert Amanogawa.Release.migrate() == :ok
    end
  end
end
