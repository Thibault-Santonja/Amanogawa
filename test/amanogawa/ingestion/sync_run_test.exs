defmodule Amanogawa.Ingestion.SyncRunTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Ingestion.SyncRun

  describe "create_changeset/2 happy path" do
    test "starts a running run with empty counts and a started_at timestamp" do
      changeset = SyncRun.create_changeset(%SyncRun{}, %{kind: :events})

      assert changeset.valid?
      assert get_field(changeset, :status) == :running
      assert get_field(changeset, :counts) == %{}
      assert %DateTime{} = get_field(changeset, :started_at)
    end

    test "accepts an initial cursor" do
      changeset = SyncRun.create_changeset(%SyncRun{}, %{kind: :events, cursor: %{"a" => 1}})

      assert get_field(changeset, :cursor) == %{"a" => 1}
    end
  end

  describe "create_changeset/2 error cases" do
    test "requires a kind" do
      changeset = SyncRun.create_changeset(%SyncRun{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).kind
    end

    test "rejects an unknown kind" do
      changeset = SyncRun.create_changeset(%SyncRun{}, %{kind: :bogus})

      refute changeset.valid?
    end
  end

  describe "progress_changeset/2" do
    test "updates counts and cursor of a running run" do
      sync_run = %SyncRun{status: :running, counts: %{"pages" => 1}}

      changeset =
        SyncRun.progress_changeset(sync_run, %{
          counts: %{"pages" => 2},
          cursor: %{"slice_index" => 0, "offset" => 3}
        })

      assert changeset.valid?
      assert get_field(changeset, :counts) == %{"pages" => 2}
      assert get_field(changeset, :cursor) == %{"slice_index" => 0, "offset" => 3}
    end

    test "rejects progressing a non-running run" do
      for status <- [:completed, :failed] do
        sync_run = %SyncRun{status: status, counts: %{}}
        changeset = SyncRun.progress_changeset(sync_run, %{counts: %{"pages" => 1}})

        refute changeset.valid?
        assert "can only progress a running sync run" in errors_on(changeset).status
      end
    end
  end

  describe "close_changeset/2" do
    test "closes a running run as completed and stamps finished_at" do
      sync_run = %SyncRun{status: :running}
      changeset = SyncRun.close_changeset(sync_run, %{status: :completed})

      assert changeset.valid?
      assert get_field(changeset, :status) == :completed
      assert %DateTime{} = get_field(changeset, :finished_at)
    end

    test "closes a running run as failed with a last_error" do
      sync_run = %SyncRun{status: :running}
      changeset = SyncRun.close_changeset(sync_run, %{status: :failed, last_error: "boom"})

      assert changeset.valid?
      assert get_field(changeset, :status) == :failed
      assert get_field(changeset, :last_error) == "boom"
    end

    test "rejects closing a non-running run (invalid transition, e.g. completed -> running)" do
      sync_run = %SyncRun{status: :completed}
      changeset = SyncRun.close_changeset(sync_run, %{status: :running})

      refute changeset.valid?
      assert "can only close a running sync run" in errors_on(changeset).status
    end

    test "rejects targeting :running even when the run is already running (no-op status change)" do
      sync_run = %SyncRun{status: :running}
      changeset = SyncRun.close_changeset(sync_run, %{status: :running})

      refute changeset.valid?
      assert "must be completed or failed" in errors_on(changeset).status
    end
  end

  describe "resume_changeset/1" do
    test "reopens a failed run to running, clearing last_error and finished_at" do
      sync_run = %SyncRun{
        status: :failed,
        last_error: "boom",
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      changeset = SyncRun.resume_changeset(sync_run)

      assert changeset.valid?
      assert get_field(changeset, :status) == :running
      assert get_field(changeset, :last_error) == nil
      assert get_field(changeset, :finished_at) == nil
    end

    test "rejects resuming a run that is not failed" do
      for status <- [:running, :completed] do
        changeset = SyncRun.resume_changeset(%SyncRun{status: status})

        refute changeset.valid?
        assert "can only resume a failed sync run" in errors_on(changeset).status
      end
    end
  end

  describe "merge_counts/2" do
    test "adds deltas to existing counters" do
      assert SyncRun.merge_counts(%{"pages" => 1, "events_fetched" => 10}, %{
               "pages" => 1,
               "events_fetched" => 5,
               "events_upserted" => 5
             }) == %{"pages" => 2, "events_fetched" => 15, "events_upserted" => 5}
    end

    test "starts from an empty map" do
      assert SyncRun.merge_counts(%{}, %{"pages" => 1}) == %{"pages" => 1}
    end
  end
end
