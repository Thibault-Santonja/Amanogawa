defmodule Amanogawa.Ingestion.Workers.PagedImport do
  @moduledoc """
  Shared orchestration for the paginated Wikidata import workers
  (`Amanogawa.Ingestion.Workers.ImportEvents` and
  `Amanogawa.Ingestion.Workers.ImportLinks`): run lifecycle, QID-slice
  cursor, pagination advance, limit accounting, chaining, closing, and
  failure handling are defined exactly once here; each worker contributes
  only what actually differs (the SPARQL template, how a page's result is
  turned into counter deltas plus a write, and the name of its "fetched"
  counter).

  ## One job, one page

  Each `perform/2` call fetches and processes exactly one page, keeping
  transactions short and every unit of work individually replayable
  (`.claude/rules/architecture.md`: no hand-rolled long-running process,
  everything is a short Oban job). A job's args carry only the reference to
  its `Amanogawa.Ingestion.SyncRun` (plus the `limit`/`dry_run` options
  given to the facade): the resume cursor `{slice_index, offset}` lives in
  the `SyncRun` row, which is the single source of truth a retried or
  resumed job reads from, never the job args themselves.

  ## Pagination plan

  The QID numeric space `[0, max_qid)` is cut into fixed-width slices
  (`slice_width`); within a slice, pages advance by `offset += page_limit`
  as long as a page comes back full (as many bindings as the `LIMIT` asked
  for); a page that comes back short moves on to the next slice at
  `offset: 0`. This makes the whole walk a stable, total, replayable order,
  matching the pagination contract of
  `Amanogawa.Ingestion.Wikidata.Templates`. `page_size`/`slice_width`/
  `max_qid` are overridable per worker via
  `config :amanogawa, WorkerModule` (used by the test suite to make small,
  fast, deterministic fixtures exercise multiple pages and slices).

  ## Errors and resumption

  A `SparqlClient` error lets Oban retry the same job (same args, same
  `sync_run_id`; the cursor already committed to the database is what the
  retry actually resumes from, since the retried job re-reads it). Once
  `max_attempts` is exhausted, the run is closed `:failed` with
  `last_error` before returning the error. An *exception* raised anywhere
  in the page processing follows the same contract: on the final attempt
  the run is closed `:failed` before the exception is re-raised, so no
  crash can leave an orphaned `:running` run behind (`try/rescue` is used
  deliberately here, at a legitimate system boundary between Oban's
  execution model and the run's persisted state). `Amanogawa.Ingestion.
  resume_events_import/1` / `resume_links_import/1` later restart a
  `:failed` run by enqueueing a fresh job for the same `sync_run_id`: the
  cursor picks up exactly where the failed run left off.

  ## `dry_run`

  Traverses the entire chain (SPARQL query, decode, counting) and only
  omits the write to `Amanogawa.Atlas` (each worker's `apply_page/3`
  implements that omission): the "upserted"/"created" counters stay `0`,
  every other counter behaves identically to a real run.

  ## Concurrency and duplication safeguards

  No Oban `:unique` option is set on these workers: the self-chaining
  design (a running job enqueues its own successor while still
  `:executing`, the very definition of an "incomplete" job) makes a
  `sync_run_id`-keyed uniqueness constraint self-conflicting, it would
  block the worker from ever chaining to its next page. Duplicate work is
  instead prevented by the `:ingestion` queue's concurrency of 1 (only one
  page processes at a time, system-wide) and by the `Amanogawa.Ingestion`
  facade refusing a second concurrent run of the same kind (application
  check plus a partial unique index on `ingestion.sync_runs`).
  """

  require Logger

  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Workers.RunGuard
  alias Amanogawa.Repo

  @default_page_size 3000
  @default_slice_width 5_000_000
  @default_max_qid 130_000_000

  @doc "Renders the SPARQL query for one page of the given slice."
  @callback page_query(%{
              lower: non_neg_integer(),
              upper: non_neg_integer(),
              limit: pos_integer(),
              offset: non_neg_integer()
            }) :: String.t()

  @doc """
  Decodes one page's `Result`, performs the write (unless `dry_run`), and
  returns the updated counts map.
  """
  @callback apply_page(counts :: map(), result :: Result.t(), dry_run :: boolean()) :: map()

  @doc "Name of the counter compared against the run's `limit` (\"events_fetched\", ...)."
  @callback fetched_count_key() :: String.t()

  @doc """
  Performs one page job on behalf of `worker` (the callback module, also
  the Oban worker whose `new/1` chains the next page). See moduledoc for
  the full lifecycle.
  """
  @spec perform(Oban.Job.t(), module()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id} = args} = job, worker) do
    sync_run = Repo.get!(SyncRun, sync_run_id)
    run(sync_run, args, job, worker)
  rescue
    exception ->
      RunGuard.close_failed_on_final_attempt(job, exception, worker)
      reraise exception, __STACKTRACE__
  end

  defp run(%SyncRun{status: :running} = sync_run, args, job, worker) do
    limit = Map.get(args, "limit")
    dry_run = Map.get(args, "dry_run", false)

    if exhausted?(sync_run.counts, limit, worker) or
         elem(cursor(sync_run), 0) >= slice_count(worker) do
      close_run(sync_run, :completed)
      :ok
    else
      process_page(sync_run, limit, dry_run, job, worker)
    end
  end

  # At-least-once delivery means a duplicate execution of an already-closed
  # run's job is always possible; treated as a safe no-op rather than a
  # crash (queue concurrency of 1 and the facade's "one running run per
  # kind" check make it rare, not impossible).
  defp run(%SyncRun{}, _args, _job, _worker), do: :ok

  defp process_page(sync_run, limit, dry_run, job, worker) do
    {slice_index, offset} = cursor(sync_run)
    {lower, upper} = slice_bounds(slice_index, worker)
    page_limit = effective_page_limit(sync_run.counts, limit, worker)

    query = worker.page_query(%{lower: lower, upper: upper, limit: page_limit, offset: offset})

    case sparql_client().query(query, []) do
      {:ok, result} ->
        handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result, worker)

      {:error, reason} ->
        handle_error(sync_run, reason, job, worker)
    end
  end

  defp handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result, worker) do
    new_counts =
      sync_run.counts
      |> SyncRun.merge_counts(%{"pages" => 1})
      |> worker.apply_page(result, dry_run)

    {next_slice_index, next_offset} =
      advance_cursor(slice_index, offset, page_limit, length(result.bindings))

    updated_run =
      sync_run
      |> SyncRun.progress_changeset(%{
        counts: new_counts,
        cursor: %{"slice_index" => next_slice_index, "offset" => next_offset}
      })
      |> Repo.update!()

    cond do
      exhausted?(new_counts, limit, worker) -> close_run(updated_run, :completed)
      next_slice_index >= slice_count(worker) -> close_run(updated_run, :completed)
      true -> enqueue_next(updated_run.id, limit, dry_run, worker)
    end

    :ok
  end

  defp handle_error(sync_run, reason, %Oban.Job{attempt: attempt, max_attempts: max}, worker) do
    Logger.warning("#{inspect(worker)} page failed: #{inspect(reason)}")

    if attempt >= max do
      close_run(sync_run, :failed, inspect(reason))
    end

    {:error, reason}
  end

  defp advance_cursor(slice_index, offset, page_limit, bindings_count) do
    if bindings_count >= page_limit do
      {slice_index, offset + page_limit}
    else
      {slice_index + 1, 0}
    end
  end

  defp cursor(%SyncRun{cursor: nil}), do: {0, 0}

  defp cursor(%SyncRun{cursor: %{"slice_index" => slice_index, "offset" => offset}}),
    do: {slice_index, offset}

  defp slice_bounds(slice_index, worker) do
    width = slice_width(worker)
    lower = slice_index * width
    {lower, lower + width}
  end

  defp slice_count(worker), do: ceil(max_qid(worker) / slice_width(worker))

  defp exhausted?(_counts, nil, _worker), do: false

  defp exhausted?(counts, limit, worker),
    do: Map.get(counts, worker.fetched_count_key(), 0) >= limit

  defp effective_page_limit(_counts, nil, worker), do: page_size(worker)

  defp effective_page_limit(counts, limit, worker) do
    remaining = limit - Map.get(counts, worker.fetched_count_key(), 0)
    min(page_size(worker), max(remaining, 1))
  end

  defp close_run(sync_run, status, last_error \\ nil) do
    sync_run
    |> SyncRun.close_changeset(%{status: status, last_error: last_error})
    |> Repo.update!()
  end

  defp enqueue_next(sync_run_id, limit, dry_run, worker) do
    {:ok, _job} =
      %{"sync_run_id" => sync_run_id, "limit" => limit, "dry_run" => dry_run}
      |> worker.new()
      |> Oban.insert()

    :ok
  end

  defp sparql_client, do: Application.get_env(:amanogawa, :sparql_client)

  defp page_size(worker), do: worker_config(worker, :page_size, @default_page_size)
  defp slice_width(worker), do: worker_config(worker, :slice_width, @default_slice_width)
  defp max_qid(worker), do: worker_config(worker, :max_qid, @default_max_qid)

  defp worker_config(worker, key, default) do
    :amanogawa |> Application.get_env(worker, []) |> Keyword.get(key, default)
  end
end
