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
end
