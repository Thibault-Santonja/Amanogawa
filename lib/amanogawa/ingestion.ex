defmodule Amanogawa.Ingestion do
  @moduledoc """
  Public API of the Ingestion bounded context: starts, resumes and observes
  the Wikidata/Wikipedia import pipelines (`Amanogawa.Ingestion.Workers.*`,
  Oban).

  This is the only module other contexts, the mix task (#013) and the Oban
  Cron schedule (#013) are meant to call into: `Amanogawa.Ingestion.SyncRun`
  and `Amanogawa.Ingestion.Workers.*` are internal, never called directly
  from outside this context.
  """

  import Ecto.Query

  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.ImportEvents
  alias Amanogawa.Repo

  @doc """
  Starts a full events import: creates a `:running` `SyncRun` and enqueues
  the first page job.

  Refuses to start a second concurrent import of the same kind: returns
  `{:error, :already_running}` when a `:running` events `SyncRun` already
  exists.

  `opts`:

    * `:limit` - caps the total number of events fetched across the whole
      run; `nil` (default) imports the entire corpus.
    * `:dry_run` - when `true`, the run walks the full chain (SPARQL query,
      decode, counting) but never writes to `Amanogawa.Atlas`. Defaults to
      `false`.
  """
  @spec start_events_import(keyword()) :: {:ok, SyncRun.t()} | {:error, :already_running}
  def start_events_import(opts \\ []) do
    if running_sync_run?(:events) do
      {:error, :already_running}
    else
      {:ok, do_start_events_import(opts)}
    end
  end

  @doc """
  Resumes a `:failed` events run from its existing `cursor`: reopens it to
  `:running` and enqueues a job referencing the same `sync_run_id`, so the
  worker resumes exactly where the failed run left off rather than
  reprocessing already-imported pages.

  Runs with `:running` or `:completed` status cannot be resumed: returns
  `{:error, changeset}` (see `SyncRun.resume_changeset/1`).
  """
  @spec resume_events_import(SyncRun.t()) :: {:ok, SyncRun.t()} | {:error, Ecto.Changeset.t()}
  def resume_events_import(%SyncRun{} = sync_run) do
    case sync_run |> SyncRun.resume_changeset() |> Repo.update() do
      {:ok, resumed} ->
        enqueue_import_job!(resumed.id, nil, false)
        {:ok, resumed}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Fetches a sync run by id, or `nil` if unknown."
  @spec get_sync_run(Ecto.UUID.t()) :: SyncRun.t() | nil
  def get_sync_run(id), do: Repo.get(SyncRun, id)

  @doc "Fetches the most recently started sync run of `kind`, or `nil` if none exists."
  @spec last_sync_run(SyncRun.kind()) :: SyncRun.t() | nil
  def last_sync_run(kind) do
    SyncRun
    |> where([s], s.kind == ^kind)
    |> order_by([s], desc: s.started_at)
    |> limit(1)
    |> Repo.one()
  end

  defp do_start_events_import(opts) do
    limit = Keyword.get(opts, :limit)
    dry_run = Keyword.get(opts, :dry_run, false)

    sync_run =
      %SyncRun{}
      |> SyncRun.create_changeset(%{kind: :events})
      |> Repo.insert!()

    enqueue_import_job!(sync_run.id, limit, dry_run)

    sync_run
  end

  defp enqueue_import_job!(sync_run_id, limit, dry_run) do
    {:ok, _job} =
      %{"sync_run_id" => sync_run_id, "limit" => limit, "dry_run" => dry_run}
      |> ImportEvents.new()
      |> Oban.insert()

    :ok
  end

  defp running_sync_run?(kind) do
    SyncRun
    |> where([s], s.kind == ^kind and s.status == :running)
    |> Repo.exists?()
  end
end
