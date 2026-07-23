defmodule Amanogawa.Ingestion.Workers.ImportEventsTest do
  use Amanogawa.DataCase, async: true

  import Mox

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SparqlClientMock
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.ImportEvents

  setup :verify_on_exit!

  # Matches config/test.exs: page_size: 3, slice_width: 10, max_qid: 20
  # (two slices, [0, 10) and [10, 20)), small enough to exercise several
  # pages and slices with tiny hand-built fixtures.

  describe "integration: full import across two slices and three pages" do
    test "walks every slice, upserts valid events, counts rejections, and completes" do
      {:ok, sync_run} = Ingestion.start_events_import()

      # Slice 0, offset 0, limit 3: a full page (Q1 ok, Q2 ok, Q3 malformed
      # WKT -> rejected). Full page: stays in slice 0, offset advances to 3.
      expect_query(fn sparql ->
        assert sparql =~ "?qidNum >= 0 && ?qidNum < 10"
        assert sparql =~ "OFFSET 0"
        {:ok, result([valid_binding("Q1"), valid_binding("Q2"), malformed_binding("Q3")])}
      end)

      # Slice 0, offset 3, limit 3: a short page (2 < 3) -> moves to slice 1.
      expect_query(fn sparql ->
        assert sparql =~ "?qidNum >= 0 && ?qidNum < 10"
        assert sparql =~ "OFFSET 3"
        {:ok, result([valid_binding("Q4"), valid_binding("Q5")])}
      end)

      # Slice 1, offset 0, limit 3: a short page -> slice 2 >= slice_count
      # (2) -> run completes.
      expect_query(fn sparql ->
        assert sparql =~ "?qidNum >= 10 && ?qidNum < 20"
        assert sparql =~ "OFFSET 0"
        {:ok, result([valid_binding("Q11"), valid_binding("Q12")])}
      end)

      run_to_completion(sync_run.id)

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.finished_at != nil

      assert final.counts == %{
               "pages" => 3,
               "events_fetched" => 7,
               "events_upserted" => 6,
               "events_rejected" => 1
             }

      assert Atlas.count_events() == 6
      assert Atlas.get_event_by_qid("Q3") == nil
    end
  end

  describe "integration: idempotence" do
    test "replaying the same import twice leaves the same row count and business columns, each run tracing its own SyncRun" do
      {:ok, first_run} = Ingestion.start_events_import()
      run_single_page_import(first_run.id, ["Q1", "Q2"])

      first_event = Atlas.get_event_by_qid("Q1")

      {:ok, second_run} = Ingestion.start_events_import()
      run_single_page_import(second_run.id, ["Q1", "Q2"])

      assert second_run.id != first_run.id
      assert Ingestion.get_sync_run(second_run.id).status == :completed

      assert Atlas.count_events() == 2
      second_event = Atlas.get_event_by_qid("Q1")

      # The full struct must survive the replay unchanged; only updated_at
      # (touched by the upsert) may differ.
      assert comparable(second_event) == comparable(first_event)
    end
  end

  describe "integration: resume after a durable error" do
    test "a run that fails durably on its second page closes :failed with the cursor on that page, and resume/1 finishes without reprocessing the first page" do
      {:ok, sync_run} = Ingestion.start_events_import()

      # Page 1 (slice 0, offset 0): succeeds, full page -> offset 3.
      expect_query(fn _sparql ->
        {:ok, result([valid_binding("Q1"), valid_binding("Q2"), valid_binding("Q3")])}
      end)

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      running = Ingestion.get_sync_run(sync_run.id)
      assert running.status == :running
      assert running.cursor == %{"slice_index" => 0, "offset" => 3}

      # Page 2 (slice 0, offset 3) fails on every attempt.
      expect_query(fn _sparql -> {:error, :timeout} end)
      expect_query(fn _sparql -> {:error, :timeout} end)

      assert {:error, :timeout} == perform_job(ImportEvents, job_args(sync_run.id), attempt: 1)
      assert Ingestion.get_sync_run(sync_run.id).status == :running

      assert {:error, :timeout} == perform_job(ImportEvents, job_args(sync_run.id), attempt: 5)

      failed = Ingestion.get_sync_run(sync_run.id)
      assert failed.status == :failed
      assert failed.last_error =~ "timeout"
      # The cursor never moved past page 1: page 2 never succeeded.
      assert failed.cursor == %{"slice_index" => 0, "offset" => 3}
      # Page 1's three events (Q1, Q2, Q3) were already committed.
      assert Atlas.count_events() == 3

      {:ok, resumed} = Ingestion.resume_events_import(failed)
      assert resumed.status == :running
      assert resumed.cursor == %{"slice_index" => 0, "offset" => 3}

      # Page 2, retried: now healthy, short page -> moves to slice 1.
      expect_query(fn _sparql -> {:ok, result([valid_binding("Q4")])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      # Slice 1, offset 0: short page -> slice 2 >= slice_count(2) -> done.
      expect_query(fn _sparql -> {:ok, result([valid_binding("Q11")])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      # 3 (page 1) + 1 (page 2, resumed) + 1 (slice 1) = 5 fetched, and Mox
      # verified exactly that many query calls (no re-fetch of page 1).
      assert final.counts["events_fetched"] == 5
      assert Atlas.count_events() == 5
    end
  end

  describe "integration: chaining" do
    test "a full page inserts exactly one following job" do
      {:ok, sync_run} = Ingestion.start_events_import()
      assert length(all_enqueued(worker: ImportEvents)) == 1

      expect_query(fn _sparql ->
        {:ok, result([valid_binding("Q1"), valid_binding("Q2"), valid_binding("Q3")])}
      end)

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      assert length(all_enqueued(worker: ImportEvents)) == 2
    end

    test "a short page in the last slice closes the run without inserting another job" do
      {:ok, sync_run} = Ingestion.start_events_import()

      # Drain both slices with empty pages to reach the last slice.
      expect_query(fn _sparql -> {:ok, result([])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))
      assert length(all_enqueued(worker: ImportEvents)) == 2

      expect_query(fn _sparql -> {:ok, result([])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      # No third job: the run closed instead.
      assert length(all_enqueued(worker: ImportEvents)) == 2
      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end
  end

  describe "edge case: empty corpus" do
    test "closes completed with the event counters at zero when every page is empty" do
      {:ok, sync_run} = Ingestion.start_events_import()

      expect_query(fn _sparql -> {:ok, result([])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      expect_query(fn _sparql -> {:ok, result([])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["events_fetched"] == 0
      assert final.counts["events_upserted"] == 0
      assert final.counts["events_rejected"] == 0
      assert Atlas.count_events() == 0
    end
  end

  describe "edge case: dry_run" do
    test "walks the full chain and counts, but never writes to Atlas" do
      {:ok, sync_run} = Ingestion.start_events_import(dry_run: true)

      expect_query(fn _sparql ->
        {:ok, result([valid_binding("Q1"), malformed_binding("Q2")])}
      end)

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id, dry_run: true))

      expect_query(fn _sparql -> {:ok, result([valid_binding("Q3")])} end)
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id, dry_run: true))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["events_fetched"] == 3
      assert final.counts["events_rejected"] == 1
      assert final.counts["events_upserted"] == 0
      assert Atlas.count_events() == 0
    end
  end

  describe "limit case: a global limit smaller than a page truncates the import" do
    test "requests a truncated LIMIT from the SPARQL template and closes once the limit is reached" do
      {:ok, sync_run} = Ingestion.start_events_import(limit: 2)

      expect_query(fn sparql ->
        assert sparql =~ "LIMIT 2"
        {:ok, result([valid_binding("Q1"), valid_binding("Q2")])}
      end)

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id, limit: 2))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["events_fetched"] == 2
      assert final.counts["events_upserted"] == 2
      assert Atlas.count_events() == 2
    end
  end

  describe "defensive: redelivery of a job for a run that is not (or no longer) actionable" do
    test "a job for an already-closed run is a safe no-op (no query, no state change)" do
      {:ok, sync_run} = Ingestion.start_events_import()

      sync_run
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      # No Mox expectation set: any query call would raise "unexpected call".
      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end

    test "a running run whose cursor already exhausted its last slice closes without querying" do
      {:ok, sync_run} = Ingestion.start_events_import()

      # slice_width: 10, max_qid: 20 (config/test.exs) -> slice_count() == 2.
      sync_run
      |> SyncRun.progress_changeset(%{cursor: %{"slice_index" => 2, "offset" => 0}})
      |> Repo.update!()

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end

    test "a running run whose counts already reached the given limit closes without querying" do
      {:ok, sync_run} = Ingestion.start_events_import(limit: 5)

      sync_run
      |> SyncRun.progress_changeset(%{counts: %{"events_fetched" => 5}})
      |> Repo.update!()

      assert :ok == perform_job(ImportEvents, job_args(sync_run.id, limit: 5))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end
  end

  describe "defensive: an exception escaping the job" do
    test "an exception on a non-final attempt leaves the run running (Oban will retry)" do
      {:ok, sync_run} = Ingestion.start_events_import()

      expect_query(fn _sparql -> raise "endpoint exploded" end)

      assert_raise RuntimeError, "endpoint exploded", fn ->
        perform_job(ImportEvents, job_args(sync_run.id), attempt: 1)
      end

      assert Ingestion.get_sync_run(sync_run.id).status == :running
    end

    test "an exception on the final attempt closes the run :failed with last_error before re-raising" do
      {:ok, sync_run} = Ingestion.start_events_import()

      expect_query(fn _sparql -> raise "endpoint exploded" end)

      assert_raise RuntimeError, "endpoint exploded", fn ->
        perform_job(ImportEvents, job_args(sync_run.id), attempt: 5)
      end

      failed = Ingestion.get_sync_run(sync_run.id)
      assert failed.status == :failed
      assert failed.last_error =~ "endpoint exploded"
      assert failed.finished_at != nil
    end

    test "an exception for a job whose run does not exist re-raises without a secondary crash" do
      missing_id = Ecto.UUID.generate()

      # Repo.get! raises (run missing); the guard must find nothing to
      # close and let the original exception through untouched.
      assert_raise Ecto.NoResultsError, fn ->
        perform_job(ImportEvents, job_args(missing_id), attempt: 5)
      end
    end
  end

  # --- helpers ---------------------------------------------------------

  defp expect_query(fun) do
    expect(SparqlClientMock, :query, fn sparql, _opts -> fun.(sparql) end)
  end

  # An Event struct stripped of everything a legitimate replay may touch:
  # only updated_at changes on an idempotent upsert.
  defp comparable(event) do
    event
    |> Map.from_struct()
    |> Map.drop([:__meta__, :updated_at])
  end

  defp job_args(sync_run_id, opts \\ []) do
    %{
      "sync_run_id" => sync_run_id,
      "limit" => Keyword.get(opts, :limit),
      "dry_run" => Keyword.get(opts, :dry_run, false)
    }
  end

  # Runs a single page (one call to the mock) through to completion,
  # assuming the page is short enough to exhaust every configured slice in
  # this one call (used by the idempotence test, where the exact pagination
  # shape does not matter, only the end-to-end result).
  defp run_single_page_import(sync_run_id, qids) do
    expect_query(fn _sparql -> {:ok, result(Enum.map(qids, &valid_binding/1))} end)
    assert :ok == perform_job(ImportEvents, job_args(sync_run_id))

    expect_query(fn _sparql -> {:ok, result([])} end)
    assert :ok == perform_job(ImportEvents, job_args(sync_run_id))
  end

  # Repeatedly performs the next page job until the run leaves :running,
  # bounded so a logic bug (infinite pagination) fails the test instead of
  # hanging it.
  defp run_to_completion(sync_run_id, max_iterations \\ 20) do
    :ok =
      Enum.reduce_while(1..max_iterations, :ok, fn _, :ok ->
        case Ingestion.get_sync_run(sync_run_id) do
          %SyncRun{status: :running} ->
            assert :ok == perform_job(ImportEvents, job_args(sync_run_id))
            {:cont, :ok}

          _closed ->
            {:halt, :ok}
        end
      end)

    refute Ingestion.get_sync_run(sync_run_id).status == :running
  end

  defp valid_binding(qid) do
    %{
      "e" => uri("http://www.wikidata.org/entity/#{qid}"),
      "beginToken" => literal("1900-01-01T00:00:00Z|9|http://www.wikidata.org/entity/Q1985727"),
      "coordDirect" => literal("POINT(2.35 48.85)")
    }
  end

  defp malformed_binding(qid) do
    Map.put(valid_binding(qid), "coordDirect", literal("NOT_A_POINT"))
  end

  defp result(bindings) do
    %Amanogawa.Ingestion.SparqlClient.Result{variables: [], bindings: bindings}
  end

  defp uri(value), do: %{value: value, type: :uri, datatype: nil, lang: nil}
  defp literal(value), do: %{value: value, type: :literal, datatype: nil, lang: nil}
end
