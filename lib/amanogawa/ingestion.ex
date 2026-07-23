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
  alias Amanogawa.Ingestion.Workers.EnrichSummaries
  alias Amanogawa.Ingestion.Workers.ImportEvents
  alias Amanogawa.Ingestion.Workers.ImportLinks
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
    with {:ok, sync_run} <- start_sync_run(:events, opts) do
      enqueue_import_job!(sync_run.id, sync_run.options)
      {:ok, sync_run}
    end
  end

  @doc """
  Resumes a `:failed` events run from its existing `cursor`: reopens it to
  `:running` and enqueues a job referencing the same `sync_run_id`, so the
  worker resumes exactly where the failed run left off rather than
  reprocessing already-imported pages. The run's persisted start `options`
  (`limit`, `dry_run`) are replayed as-is: a resumed dry run stays a dry
  run.

  Runs with `:running` or `:completed` status cannot be resumed: returns
  `{:error, changeset}` (see `SyncRun.resume_changeset/1`).
  """
  @spec resume_events_import(SyncRun.t()) :: {:ok, SyncRun.t()} | {:error, Ecto.Changeset.t()}
  def resume_events_import(%SyncRun{} = sync_run) do
    case sync_run |> SyncRun.resume_changeset() |> Repo.update() do
      {:ok, resumed} ->
        enqueue_import_job!(resumed.id, resumed.options)
        {:ok, resumed}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Starts a full relations import: creates a `:running` `SyncRun` of kind
  `:links` and enqueues the first page job.

  Refuses to start a second concurrent import of the same kind: returns
  `{:error, :already_running}` when a `:running` links `SyncRun` already
  exists. Does not require an `:events` run to be finished first: running
  it against an empty or partial local corpus is safe, if of limited use
  (`Amanogawa.Ingestion.Workers.ImportLinks`'s moduledoc).

  `opts`:

    * `:limit` - caps the total number of relation bindings fetched across
      the whole run; `nil` (default) imports the entire corpus.
    * `:dry_run` - when `true`, the run walks the full chain (SPARQL query,
      decode, counting) but never writes to `Amanogawa.Atlas`. Defaults to
      `false`.
  """
  @spec start_links_import(keyword()) :: {:ok, SyncRun.t()} | {:error, :already_running}
  def start_links_import(opts \\ []) do
    with {:ok, sync_run} <- start_sync_run(:links, opts) do
      enqueue_links_job!(sync_run.id, sync_run.options)
      {:ok, sync_run}
    end
  end

  @doc """
  Resumes a `:failed` links run from its existing `cursor`: reopens it to
  `:running` and enqueues a job referencing the same `sync_run_id`, so the
  worker resumes exactly where the failed run left off rather than
  reprocessing already-imported pages. The run's persisted start `options`
  (`limit`, `dry_run`) are replayed as-is: a resumed dry run stays a dry
  run.

  Runs with `:running` or `:completed` status cannot be resumed: returns
  `{:error, changeset}` (see `SyncRun.resume_changeset/1`).
  """
  @spec resume_links_import(SyncRun.t()) :: {:ok, SyncRun.t()} | {:error, Ecto.Changeset.t()}
  def resume_links_import(%SyncRun{} = sync_run) do
    case sync_run |> SyncRun.resume_changeset() |> Repo.update() do
      {:ok, resumed} ->
        enqueue_links_job!(resumed.id, resumed.options)
        {:ok, resumed}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Starts a Wikipedia summaries enrichment run (#012): creates a `:running`
  `SyncRun` and enqueues the first batch job.

  Refuses to start a second concurrent run of the same kind: returns
  `{:error, :already_running}` when a `:running` summaries `SyncRun`
  already exists.

  `opts`:

    * `:limit` - caps the total number of summaries fetched across the
      whole run; `nil` (default) enriches every eligible event.
    * `:dry_run` - when `true`, the run walks the full chain (selection,
      fetch, counting) but never writes to `Amanogawa.Atlas`. Defaults to
      `false`.
    * `:max_age_days` - overrides the configured cache freshness window for
      this run only.
  """
  @spec start_summaries_enrichment(keyword()) :: {:ok, SyncRun.t()} | {:error, :already_running}
  def start_summaries_enrichment(opts \\ []) do
    max_age_days = Keyword.get(opts, :max_age_days)

    with {:ok, sync_run} <- start_sync_run(:summaries, opts, %{"max_age_days" => max_age_days}) do
      enqueue_enrich_job!(sync_run.id, sync_run.options)
      {:ok, sync_run}
    end
  end

  @doc """
  Blocks the caller until `sync_run` reaches a terminal status (`:completed`
  or `:failed`), by polling `Amanogawa.Ingestion.SyncRun` every
  `:poll_interval_ms` (default 200ms) up to `:timeout_ms` (default 5
  minutes). Returns `{:ok, closed_run}` once terminal, or
  `{:error, :timeout}` if the deadline elapses first: the run itself is left
  untouched (still `:running`) in that case, only the wait gives up.

  `:on_progress`, when given, is called with the freshly re-fetched
  `SyncRun` on every poll (including the very first, and the last, terminal
  one): the mix task (#013) uses this to report counters and cursor as a
  run advances, without this facade having to know anything about how that
  progress is displayed.

  This is a synchronous convenience for callers that need to observe a
  run's outcome without subscribing to Oban telemetry: the mix task
  (#013) uses it to wait for each step of an `all` sync before starting the
  next. Meant for runs actually progressing in the background (a normal
  Oban queue polling for jobs); it does not itself drive job execution.
  """
  @spec await_run(SyncRun.t(), keyword()) :: {:ok, SyncRun.t()} | {:error, :timeout}
  def await_run(%SyncRun{id: id}, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, :timer.minutes(5))
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 200)
    on_progress = Keyword.get(opts, :on_progress, fn _sync_run -> :ok end)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until_closed(id, deadline, poll_interval_ms, on_progress)
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

  # Creates the `:running` SyncRun row, persisting the start options
  # (`limit`, `dry_run`, plus `extra_options` for kind-specific ones) so a
  # later resume replays exactly what was asked. Concurrency is enforced
  # twice: a friendly pre-check for the common case, and the
  # `sync_runs_running_kind_index` partial unique index for the race two
  # simultaneous starts would otherwise win together.
  defp start_sync_run(kind, opts, extra_options \\ %{}) do
    if running_sync_run?(kind) do
      {:error, :already_running}
    else
      options =
        Map.merge(
          %{
            "limit" => Keyword.get(opts, :limit),
            "dry_run" => Keyword.get(opts, :dry_run, false)
          },
          extra_options
        )

      %SyncRun{}
      |> SyncRun.create_changeset(%{kind: kind, options: options})
      |> Repo.insert()
      |> case do
        {:ok, sync_run} -> {:ok, sync_run}
        {:error, %Ecto.Changeset{}} -> {:error, :already_running}
      end
    end
  end

  defp enqueue_enrich_job!(sync_run_id, options) do
    {:ok, _job} =
      options
      |> job_args(sync_run_id)
      |> EnrichSummaries.new()
      |> Oban.insert()

    :ok
  end

  defp enqueue_import_job!(sync_run_id, options) do
    {:ok, _job} =
      options
      |> job_args(sync_run_id)
      |> ImportEvents.new()
      |> Oban.insert()

    :ok
  end

  defp enqueue_links_job!(sync_run_id, options) do
    {:ok, _job} =
      options
      |> job_args(sync_run_id)
      |> ImportLinks.new()
      |> Oban.insert()

    :ok
  end

  defp job_args(options, sync_run_id) when is_map(options) do
    Map.put(options, "sync_run_id", sync_run_id)
  end

  defp running_sync_run?(kind) do
    SyncRun
    |> where([s], s.kind == ^kind and s.status == :running)
    |> Repo.exists?()
  end

  defp poll_until_closed(id, deadline, poll_interval_ms, on_progress) do
    sync_run = get_sync_run(id)
    on_progress.(sync_run)

    case sync_run do
      %SyncRun{status: status} when status in [:completed, :failed] ->
        {:ok, sync_run}

      %SyncRun{} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(poll_interval_ms)
          poll_until_closed(id, deadline, poll_interval_ms, on_progress)
        end
    end
  end
end
