defmodule Amanogawa.IngestionTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.ImportEvents
  alias Amanogawa.Ingestion.Workers.ImportLinks
  alias Amanogawa.Repo

  describe "start_events_import/1 happy path" do
    test "creates a running SyncRun and enqueues the first page job" do
      assert {:ok, %SyncRun{kind: :events, status: :running} = sync_run} =
               Ingestion.start_events_import()

      assert_enqueued(worker: ImportEvents, args: %{"sync_run_id" => sync_run.id})
    end

    test "carries limit and dry_run into the first job's args" do
      assert {:ok, sync_run} = Ingestion.start_events_import(limit: 100, dry_run: true)

      assert_enqueued(
        worker: ImportEvents,
        args: %{"sync_run_id" => sync_run.id, "limit" => 100, "dry_run" => true}
      )
    end
  end

  describe "start_events_import/1 error cases" do
    test "refuses a second concurrent import of the same kind" do
      assert {:ok, _first} = Ingestion.start_events_import()
      assert {:error, :already_running} = Ingestion.start_events_import()
    end

    test "does not refuse starting :events while a :links run of a different kind is running" do
      %SyncRun{}
      |> SyncRun.create_changeset(%{kind: :links})
      |> Repo.insert!()

      assert {:ok, _sync_run} = Ingestion.start_events_import()
    end

    test "allows starting a new import once the previous one is closed" do
      {:ok, first} = Ingestion.start_events_import()

      first
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      assert {:ok, _second} = Ingestion.start_events_import()
    end
  end

  describe "resume_events_import/1" do
    test "reopens a failed run to running and enqueues a job for the same sync_run_id" do
      {:ok, sync_run} = Ingestion.start_events_import()

      failed =
        sync_run
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      assert {:ok, %SyncRun{status: :running, last_error: nil}} =
               Ingestion.resume_events_import(failed)

      assert_enqueued(worker: ImportEvents, args: %{"sync_run_id" => sync_run.id})
    end

    test "rejects resuming a run that is not failed" do
      {:ok, sync_run} = Ingestion.start_events_import()

      assert {:error, changeset} = Ingestion.resume_events_import(sync_run)
      refute changeset.valid?
    end

    test "replays the persisted start options: a resumed dry run stays a dry run, with its limit" do
      {:ok, sync_run} = Ingestion.start_events_import(limit: 42, dry_run: true)

      failed =
        sync_run
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      assert {:ok, _resumed} = Ingestion.resume_events_import(failed)

      assert_enqueued(
        worker: ImportEvents,
        args: %{"sync_run_id" => sync_run.id, "limit" => 42, "dry_run" => true}
      )
    end
  end

  describe "start_links_import/1 happy path" do
    test "creates a running SyncRun of kind :links and enqueues the first page job" do
      assert {:ok, %SyncRun{kind: :links, status: :running} = sync_run} =
               Ingestion.start_links_import()

      assert_enqueued(worker: ImportLinks, args: %{"sync_run_id" => sync_run.id})
    end

    test "carries limit and dry_run into the first job's args" do
      assert {:ok, sync_run} = Ingestion.start_links_import(limit: 100, dry_run: true)

      assert_enqueued(
        worker: ImportLinks,
        args: %{"sync_run_id" => sync_run.id, "limit" => 100, "dry_run" => true}
      )
    end
  end

  describe "start_links_import/1 error cases" do
    test "refuses a second concurrent import of the same kind" do
      assert {:ok, _first} = Ingestion.start_links_import()
      assert {:error, :already_running} = Ingestion.start_links_import()
    end

    test "does not refuse starting :links while an :events run of a different kind is running" do
      {:ok, _events_run} = Ingestion.start_events_import()

      assert {:ok, _links_run} = Ingestion.start_links_import()
    end

    test "allows starting a new import once the previous one is closed" do
      {:ok, first} = Ingestion.start_links_import()

      first
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      assert {:ok, _second} = Ingestion.start_links_import()
    end
  end

  describe "resume_links_import/1" do
    test "reopens a failed run to running and enqueues a job for the same sync_run_id" do
      {:ok, sync_run} = Ingestion.start_links_import()

      failed =
        sync_run
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      assert {:ok, %SyncRun{status: :running, last_error: nil}} =
               Ingestion.resume_links_import(failed)

      assert_enqueued(worker: ImportLinks, args: %{"sync_run_id" => sync_run.id})
    end

    test "rejects resuming a run that is not failed" do
      {:ok, sync_run} = Ingestion.start_links_import()

      assert {:error, changeset} = Ingestion.resume_links_import(sync_run)
      refute changeset.valid?
    end

    test "replays the persisted start options: a resumed dry run stays a dry run, with its limit" do
      {:ok, sync_run} = Ingestion.start_links_import(limit: 7, dry_run: true)

      failed =
        sync_run
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      assert {:ok, _resumed} = Ingestion.resume_links_import(failed)

      assert_enqueued(
        worker: ImportLinks,
        args: %{"sync_run_id" => sync_run.id, "limit" => 7, "dry_run" => true}
      )
    end
  end

  describe "concurrency: the partial unique index backs the facade check" do
    test "an insert racing past the application check surfaces as a changeset error, not a crash" do
      {:ok, _running} = Ingestion.start_events_import()

      # Simulates the losing side of a start race: the application-level
      # exists? check has been passed (bypassed here), the partial unique
      # index (one :running run per kind) must refuse the insert cleanly.
      assert {:error, changeset} =
               %SyncRun{}
               |> SyncRun.create_changeset(%{kind: :events})
               |> Repo.insert()

      assert "a running sync run of this kind already exists" in errors_on(changeset).kind
    end

    test "resuming a failed run while another run of the same kind is running is refused cleanly" do
      {:ok, first} = Ingestion.start_events_import()

      failed =
        first
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      {:ok, _second_running} = Ingestion.start_events_import()

      assert {:error, changeset} = Ingestion.resume_events_import(failed)
      assert "a running sync run of this kind already exists" in errors_on(changeset).kind
    end
  end

  describe "await_run/2" do
    test "returns immediately when the run is already closed" do
      {:ok, sync_run} = Ingestion.start_events_import()

      closed =
        sync_run
        |> SyncRun.close_changeset(%{status: :completed})
        |> Repo.update!()

      assert {:ok, %SyncRun{status: :completed}} =
               Ingestion.await_run(closed, timeout_ms: 1000, poll_interval_ms: 1000)
    end

    test "polls until the run closes, calling on_progress on every tick" do
      {:ok, sync_run} = Ingestion.start_events_import()
      ticks = :counters.new(1, [])

      on_progress = fn run ->
        :counters.add(ticks, 1, 1)

        if run.status == :running and :counters.get(ticks, 1) >= 2 do
          run |> SyncRun.close_changeset(%{status: :completed}) |> Repo.update!()
        end
      end

      assert {:ok, %SyncRun{status: :completed}} =
               Ingestion.await_run(sync_run,
                 timeout_ms: 1000,
                 poll_interval_ms: 1,
                 on_progress: on_progress
               )

      assert :counters.get(ticks, 1) >= 2
    end

    test "returns {:error, :timeout} when the run never closes before the deadline" do
      {:ok, sync_run} = Ingestion.start_events_import()

      assert {:error, :timeout} =
               Ingestion.await_run(sync_run, timeout_ms: 5, poll_interval_ms: 1)

      assert Ingestion.get_sync_run(sync_run.id).status == :running
    end

    test "defaults on_progress to a no-op when not given" do
      {:ok, sync_run} = Ingestion.start_events_import()

      closed =
        sync_run
        |> SyncRun.close_changeset(%{status: :completed})
        |> Repo.update!()

      assert {:ok, %SyncRun{status: :completed}} = Ingestion.await_run(closed)
    end

    test "closes on a :failed status too, not only :completed" do
      {:ok, sync_run} = Ingestion.start_events_import()

      failed =
        sync_run
        |> SyncRun.close_changeset(%{status: :failed, last_error: "boom"})
        |> Repo.update!()

      assert {:ok, %SyncRun{status: :failed}} =
               Ingestion.await_run(failed, timeout_ms: 1000, poll_interval_ms: 1000)
    end
  end

  describe "get_sync_run/1 and last_sync_run/1" do
    test "get_sync_run/1 returns nil for an unknown id" do
      assert Ingestion.get_sync_run(Ecto.UUID.generate()) == nil
    end

    test "get_sync_run/1 fetches an existing run" do
      {:ok, sync_run} = Ingestion.start_events_import()

      assert %SyncRun{id: id} = Ingestion.get_sync_run(sync_run.id)
      assert id == sync_run.id
    end

    test "last_sync_run/1 returns nil when no run of that kind exists" do
      assert Ingestion.last_sync_run(:events) == nil
    end

    test "last_sync_run/1 returns the most recently started run of the given kind" do
      {:ok, first} = Ingestion.start_events_import()

      first
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      # A distinct started_at guarantees a deterministic "most recent" even
      # though both runs are created within the same test.
      later = DateTime.utc_now() |> DateTime.add(10, :second) |> DateTime.truncate(:second)

      %SyncRun{}
      |> SyncRun.create_changeset(%{kind: :events})
      |> Ecto.Changeset.put_change(:started_at, later)
      |> Repo.insert!()
      |> then(fn second -> assert Ingestion.last_sync_run(:events).id == second.id end)
    end
  end

  describe "import_cliopatria/1" do
    @fixture Path.join([__DIR__, "..", "support", "fixtures", "cliopatria", "sample.geojson"])

    test "delegates to Amanogawa.Ingestion.Cliopatria.Importer.import/1" do
      assert {:ok, summary} = Ingestion.import_cliopatria(@fixture)
      assert summary.inserted == 3
      assert Amanogawa.Atlas.count_borders() == 3
    end
  end

  describe "import_historical_basemaps/1" do
    @fixture_dir Path.join([__DIR__, "..", "support", "fixtures", "historical_basemaps"])

    test "delegates to Amanogawa.Ingestion.HistoricalBasemaps.Importer.import/1" do
      assert {:ok, summary} = Ingestion.import_historical_basemaps(@fixture_dir)
      assert summary.inserted == 3
      assert Amanogawa.Atlas.count_borders() == 3
    end
  end
end
