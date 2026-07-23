defmodule Amanogawa.Ingestion.Workers.ImportLinksTest do
  use Amanogawa.DataCase, async: true

  import Mox

  alias Amanogawa.Atlas
  alias Amanogawa.AtlasFixtures
  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SparqlClientMock
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.ImportLinks
  alias Amanogawa.SparqlFixtures

  setup :verify_on_exit!

  # Matches config/test.exs: page_size: 3, slice_width: 10, max_qid: 20
  # (two slices, [0, 10) and [10, 20)), same shape as ImportEventsTest.

  describe "integration: exact counts against a real, partially preloaded relations page" do
    test "creates only links whose both endpoints exist locally, deduplicates, and tallies by property" do
      # Preload exactly the endpoints of 4 of the 7 distinct links the
      # fixture decodes to (see test/support/fixtures/sparql/README.md for
      # the raw data and its provenance): the other 3 stay skipped_missing.
      AtlasFixtures.event_fixture(qid: "Q178510")
      AtlasFixtures.event_fixture(qid: "Q124785345")
      AtlasFixtures.event_fixture(qid: "Q917167")
      AtlasFixtures.event_fixture(qid: "Q178975")
      AtlasFixtures.event_fixture(qid: "Q188709")
      AtlasFixtures.event_fixture(qid: "Q19979612")
      AtlasFixtures.event_fixture(qid: "Q844930")
      AtlasFixtures.event_fixture(qid: "Q16683515")

      {:ok, sync_run} = Ingestion.start_links_import()

      # Fixture page: 9 bindings >= page_size (3, config/test.exs) -> a
      # "full" page, stays in slice 0, offset advances to 3.
      expect_query(fn _sparql -> SparqlFixtures.sparql_fixture("links_page.json") end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      # Slice 0, offset 3: short (empty) page -> moves to slice 1.
      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      # Slice 1, offset 0: short page -> slice 2 >= slice_count (2) -> done.
      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed

      assert final.counts["pages"] == 3
      assert final.counts["links_fetched"] == 9
      assert final.counts["links_rejected"] == 1
      # 7 distinct links after dedup: Q178510/Q124785345 (part_of, P361,
      # created), Q178842/Q16512674 (part_of, P361, both missing locally,
      # skipped), Q917167/Q178975 (follows, deduplicated from P156+P155,
      # created), Q178809/Q109886 (follows, P155, both missing, skipped),
      # Q188709/Q19979612 (significant, P793, created), Q208433/Q176883
      # (part_of, P1344, both missing, skipped), Q844930/Q16683515
      # (part_of, P1344, created). 4 created, 3 skipped_missing.
      assert final.counts["links_created"] == 4
      assert final.counts["links_skipped_missing"] == 3

      assert final.counts["by_property"] == %{
               "P361" => 2,
               "P156" => 1,
               "P155" => 1,
               "P793" => 1,
               "P1344" => 2
             }

      assert Atlas.count_event_links() == 4
    end
  end

  describe "integration: idempotence" do
    test "replaying the same import twice leaves the same link count, each run tracing its own SyncRun" do
      source = AtlasFixtures.event_fixture()
      target = AtlasFixtures.event_fixture()

      {:ok, first_run} = Ingestion.start_links_import()
      run_single_page_import(first_run.id, source.qid, target.qid)

      {:ok, second_run} = Ingestion.start_links_import()
      run_single_page_import(second_run.id, source.qid, target.qid)

      assert second_run.id != first_run.id
      assert Ingestion.get_sync_run(second_run.id).status == :completed
      assert Atlas.count_event_links() == 1
    end
  end

  describe "integration: resume after a durable error" do
    test "a run that fails durably closes :failed with the cursor, and resume/1 finishes without reprocessing" do
      source = AtlasFixtures.event_fixture()
      target = AtlasFixtures.event_fixture()

      {:ok, sync_run} = Ingestion.start_links_import()

      expect_query(fn _sparql -> {:ok, part_of_result(source.qid, target.qid)} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      running = Ingestion.get_sync_run(sync_run.id)
      assert running.status == :running
      assert running.cursor == %{"slice_index" => 1, "offset" => 0}
      assert Atlas.count_event_links() == 1

      expect_query(fn _sparql -> {:error, :timeout} end)
      expect_query(fn _sparql -> {:error, :timeout} end)

      assert {:error, :timeout} == perform_job(ImportLinks, job_args(sync_run.id), attempt: 1)
      assert Ingestion.get_sync_run(sync_run.id).status == :running

      assert {:error, :timeout} == perform_job(ImportLinks, job_args(sync_run.id), attempt: 5)

      failed = Ingestion.get_sync_run(sync_run.id)
      assert failed.status == :failed
      assert failed.last_error =~ "timeout"
      assert failed.cursor == %{"slice_index" => 1, "offset" => 0}

      {:ok, resumed} = Ingestion.resume_links_import(failed)
      assert resumed.status == :running

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["links_created"] == 1
      assert Atlas.count_event_links() == 1
    end
  end

  describe "integration: chaining" do
    test "a full page inserts exactly one following job" do
      {:ok, sync_run} = Ingestion.start_links_import()
      assert length(all_enqueued(worker: ImportLinks)) == 1

      expect_query(fn _sparql ->
        {:ok,
         %Amanogawa.Ingestion.SparqlClient.Result{
           variables: ["source", "target", "property"],
           bindings: [
             link_binding("Q1", "Q2"),
             link_binding("Q3", "Q4"),
             link_binding("Q5", "Q6")
           ]
         }}
      end)

      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      assert length(all_enqueued(worker: ImportLinks)) == 2
    end

    test "a short page in the last slice closes the run without inserting another job" do
      {:ok, sync_run} = Ingestion.start_links_import()

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))
      assert length(all_enqueued(worker: ImportLinks)) == 2

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      assert length(all_enqueued(worker: ImportLinks)) == 2
      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end
  end

  describe "edge case: empty corpus" do
    test "closes completed with the link counters at zero when every page is empty" do
      {:ok, sync_run} = Ingestion.start_links_import()

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["links_fetched"] == 0
      assert final.counts["links_created"] == 0
      assert final.counts["links_skipped_missing"] == 0
      assert final.counts["links_rejected"] == 0
      assert Atlas.count_event_links() == 0
    end
  end

  describe "edge case: a page containing only links to events absent locally" do
    test "counts every link as skipped_missing, creates nothing" do
      {:ok, sync_run} = Ingestion.start_links_import()

      expect_query(fn _sparql -> {:ok, part_of_result("Q900001", "Q900002")} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["links_created"] == 0
      assert final.counts["links_skipped_missing"] == 1
      assert Atlas.count_event_links() == 0
    end
  end

  describe "edge case: dry_run" do
    test "walks the full chain and counts, but never writes to Atlas" do
      source = AtlasFixtures.event_fixture()
      target = AtlasFixtures.event_fixture()

      {:ok, sync_run} = Ingestion.start_links_import(dry_run: true)

      expect_query(fn _sparql -> {:ok, part_of_result(source.qid, target.qid)} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id, dry_run: true))

      expect_query(fn _sparql -> {:ok, empty_result()} end)
      assert :ok == perform_job(ImportLinks, job_args(sync_run.id, dry_run: true))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["links_fetched"] == 1
      assert final.counts["links_created"] == 0
      assert final.counts["links_skipped_missing"] == 0
      assert Atlas.count_event_links() == 0
    end
  end

  describe "limit case: a global limit smaller than a page truncates the import" do
    test "requests a truncated LIMIT from the SPARQL template and closes once the limit is reached" do
      {:ok, sync_run} = Ingestion.start_links_import(limit: 2)

      expect_query(fn sparql ->
        assert sparql =~ "LIMIT 2"

        {:ok,
         %Amanogawa.Ingestion.SparqlClient.Result{
           variables: [],
           bindings: [link_binding("Q1", "Q2"), link_binding("Q3", "Q4")]
         }}
      end)

      assert :ok == perform_job(ImportLinks, job_args(sync_run.id, limit: 2))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["links_fetched"] == 2
    end
  end

  describe "defensive: redelivery of a job for a run that is not (or no longer) actionable" do
    test "a job for an already-closed run is a safe no-op (no query, no state change)" do
      {:ok, sync_run} = Ingestion.start_links_import()

      sync_run
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end

    test "a running run whose cursor already exhausted its last slice closes without querying" do
      {:ok, sync_run} = Ingestion.start_links_import()

      # slice_width: 10, max_qid: 20 (config/test.exs) -> slice_count() == 2.
      sync_run
      |> SyncRun.progress_changeset(%{cursor: %{"slice_index" => 2, "offset" => 0}})
      |> Repo.update!()

      assert :ok == perform_job(ImportLinks, job_args(sync_run.id))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end

    test "a running run whose counts already reached the given limit closes without querying" do
      {:ok, sync_run} = Ingestion.start_links_import(limit: 5)

      sync_run
      |> SyncRun.progress_changeset(%{counts: %{"links_fetched" => 5}})
      |> Repo.update!()

      assert :ok == perform_job(ImportLinks, job_args(sync_run.id, limit: 5))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end
  end

  # --- helpers ---------------------------------------------------------

  defp expect_query(fun) do
    expect(SparqlClientMock, :query, fn sparql, _opts -> fun.(sparql) end)
  end

  defp job_args(sync_run_id, opts \\ []) do
    %{
      "sync_run_id" => sync_run_id,
      "limit" => Keyword.get(opts, :limit),
      "dry_run" => Keyword.get(opts, :dry_run, false)
    }
  end

  defp run_single_page_import(sync_run_id, source_qid, target_qid) do
    expect_query(fn _sparql -> {:ok, part_of_result(source_qid, target_qid)} end)
    assert :ok == perform_job(ImportLinks, job_args(sync_run_id))

    expect_query(fn _sparql -> {:ok, empty_result()} end)
    assert :ok == perform_job(ImportLinks, job_args(sync_run_id))
  end

  defp empty_result, do: %Amanogawa.Ingestion.SparqlClient.Result{variables: [], bindings: []}

  defp part_of_result(source_qid, target_qid) do
    %Amanogawa.Ingestion.SparqlClient.Result{
      variables: ["source", "target", "property"],
      bindings: [link_binding(source_qid, target_qid)]
    }
  end

  defp link_binding(source_qid, target_qid) do
    %{"source" => uri(source_qid), "target" => uri(target_qid), "property" => literal("P361")}
  end

  defp uri(qid),
    do: %{value: "http://www.wikidata.org/entity/#{qid}", type: :uri, datatype: nil, lang: nil}

  defp literal(value), do: %{value: value, type: :literal, datatype: nil, lang: nil}
end
