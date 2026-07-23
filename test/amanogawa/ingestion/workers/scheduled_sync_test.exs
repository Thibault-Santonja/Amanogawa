defmodule Amanogawa.Ingestion.Workers.ScheduledSyncTest do
  use Amanogawa.DataCase, async: true

  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.ScheduledSync

  describe "perform/1" do
    test "kind events starts an events sync run" do
      assert :ok == perform_job(ScheduledSync, %{"kind" => "events"})

      assert %SyncRun{kind: :events, status: :running} = Ingestion.last_sync_run(:events)
    end

    test "kind links starts a links sync run" do
      assert :ok == perform_job(ScheduledSync, %{"kind" => "links"})

      assert %SyncRun{kind: :links, status: :running} = Ingestion.last_sync_run(:links)
    end

    test "kind summaries starts a summaries sync run" do
      assert :ok == perform_job(ScheduledSync, %{"kind" => "summaries"})

      assert %SyncRun{kind: :summaries, status: :running} = Ingestion.last_sync_run(:summaries)
    end

    test "an overlapping tick on a still-running kind is a safe no-op" do
      {:ok, already_running} = Ingestion.start_events_import()

      assert :ok == perform_job(ScheduledSync, %{"kind" => "events"})

      # No second run started: the only :events run is still the one
      # started directly above.
      assert Ingestion.last_sync_run(:events).id == already_running.id
    end
  end
end
