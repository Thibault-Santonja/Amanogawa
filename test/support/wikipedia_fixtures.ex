defmodule Amanogawa.WikipediaFixtures do
  @moduledoc """
  Loads Wikipedia `page/summary` fixtures recorded from the real REST API
  (see `test/support/fixtures/wikipedia/README.md` for provenance and
  capture dates). No test ever calls the real Wikipedia endpoint
  (`.claude/rules/testing.md`): this module is the single place ingestion
  tests load fixtures from, reused by the `WikipediaClient.Rest` adapter
  tests and by every consumer of `Amanogawa.Ingestion.WikipediaClientMock`.
  """

  @fixtures_dir Path.join([__DIR__, "fixtures", "wikipedia"])

  @doc """
  Reads a fixture file's raw contents, exactly as received over the wire.
  Used to stub the transport layer (`Req.Test`) when testing the adapter
  directly, or to feed a hostile fixture (malformed JSON) to
  `Amanogawa.Ingestion.WikipediaClient.Summary.decode/2`.
  """
  @spec raw_wikipedia_fixture(String.t() | atom()) :: String.t()
  def raw_wikipedia_fixture(name) do
    @fixtures_dir
    |> Path.join(to_string(name))
    |> File.read!()
  end
end
