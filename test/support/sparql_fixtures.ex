defmodule Amanogawa.SparqlFixtures do
  @moduledoc """
  Loads SPARQL results fixtures recorded from the real QLever endpoint (see
  `test/support/fixtures/sparql/README.md` for provenance, queries, and
  capture dates). Fixtures are decoded through the same parser used in
  production (`Amanogawa.Ingestion.SparqlClient.Result.decode/1`), never
  hand-crafted structs, so a decoding regression cannot hide behind a fixture
  that does not reflect the real wire format.

  No test ever calls a real SPARQL endpoint (`.claude/rules/testing.md`):
  this module is the single place ingestion tests load fixtures from, reused
  by the `SparqlClient.QLever` adapter tests and by every consumer of
  `Amanogawa.Ingestion.SparqlClientMock`.
  """

  alias Amanogawa.Ingestion.SparqlClient.Result

  @fixtures_dir Path.join([__DIR__, "fixtures", "sparql"])

  @doc """
  Reads a fixture file's raw contents, exactly as received over the wire.
  Used to stub the transport layer (`Req.Test`) when testing an adapter
  directly, or to feed a hostile fixture (malformed JSON, HTML error page)
  that the fixture-level `sparql_fixture/1` cannot represent as a `Result`.
  """
  @spec raw_sparql_fixture(String.t() | atom()) :: String.t()
  def raw_sparql_fixture(name) do
    @fixtures_dir
    |> Path.join(to_string(name))
    |> File.read!()
  end

  @doc """
  Loads a fixture and decodes it into `{:ok, Result.t()}`, ready to be
  returned directly by `Amanogawa.Ingestion.SparqlClientMock`:

      Mox.expect(Amanogawa.Ingestion.SparqlClientMock, :query, fn _sparql, _opts ->
        sparql_fixture("nominal.json")
      end)

  """
  @spec sparql_fixture(String.t() | atom()) :: {:ok, Result.t()}
  def sparql_fixture(name) do
    {:ok, name |> raw_sparql_fixture() |> Result.decode!()}
  end
end
