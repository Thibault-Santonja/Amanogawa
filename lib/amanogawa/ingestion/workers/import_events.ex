defmodule Amanogawa.Ingestion.Workers.ImportEvents do
  @moduledoc """
  Oban worker orchestrating the Wikidata event import: pages through the
  QID space with `Amanogawa.Ingestion.Wikidata.Templates.events_page/1`,
  decodes each page with `Amanogawa.Ingestion.Wikidata.EventDecoder`, and
  writes the result through `Amanogawa.Atlas.upsert_events/1` (never
  `Amanogawa.Atlas.Event` nor `Amanogawa.Repo` directly: Ingestion never
  bypasses the Atlas facade).

  ## One job, one page

  Each execution of `perform/1` fetches and processes exactly one page,
  keeping transactions short and every unit of work individually replayable
  (`.claude/rules/architecture.md`: no hand-rolled long-running process,
  everything is a short Oban job). A job's args carry only the reference to
  its `Amanogawa.Ingestion.SyncRun` (plus the `limit`/`dry_run` options
  given to the facade): the resume cursor `{slice_index, offset}` lives in
  the `SyncRun` row, which is the single source of truth a retried or
  resumed job reads from, never the job args themselves.

  ## Pagination plan

  The QID numeric space `[0, max_qid)` is cut into fixed-width slices
  (`slice_width`); within a slice, pages advance by `offset += page_limit`
  as long as a page comes back full (as many bindings as the `LIMIT`
  asked for); a page that comes back short moves on to the next slice at
  `offset: 0`. This makes the whole walk a stable, total, replayable order,
  matching the pagination contract of `Amanogawa.Ingestion.Wikidata.
  Templates.events_page/1`. `page_size`/`slice_width`/`max_qid` are
  overridable via `config :amanogawa, #{inspect(__MODULE__)}` (used by the
  test suite to make small, fast, deterministic fixtures exercise multiple
  pages and slices).

  ## Errors and resumption

  A `SparqlClient` error lets Oban retry the same job (same args, same
  `sync_run_id`; the cursor already committed to the database is what the
  retry actually resumes from, since the retried job re-reads it). Once
  `max_attempts` is exhausted, the run is closed `:failed` with
  `last_error` before returning the error, so the `SyncRun` row reflects
  reality without needing a separate telemetry hook. `Amanogawa.Ingestion.
  resume_events_import/1` later restarts a `:failed` run by enqueueing a
  fresh job for the same `sync_run_id`: the cursor picks up exactly where
  the failed run left off.

  ## `dry_run`

  Traverses the entire chain (SPARQL query, decode, counting) and only
  omits the `Amanogawa.Atlas.upsert_events/1` call: `events_upserted` stays
  `0`, every other counter behaves identically to a real run. This is what
  the sync mix task (#013) uses to preview an import.

  ## Concurrency and duplication safeguards

  No Oban `:unique` option is set on this worker: the self-chaining design
  (a running job enqueues its own successor while still `:executing`, the
  very definition of an "incomplete" job) makes a `sync_run_id`-keyed
  uniqueness constraint self-conflicting, it would block the worker from
  ever chaining to its next page. Duplicate work is instead prevented by
  the `:ingestion` queue's concurrency of 1 (only one page processes at a
  time, system-wide) and by `Amanogawa.Ingestion.start_events_import/1`
  refusing a second concurrent run of the same kind.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  require Logger

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Wikidata.EventDecoder
  alias Amanogawa.Ingestion.Wikidata.ExtractedEvent
  alias Amanogawa.Ingestion.Wikidata.Templates
  alias Amanogawa.Repo

  @default_page_size 3000
  @default_slice_width 5_000_000
  @default_max_qid 130_000_000

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id} = args} = job) do
    sync_run = Repo.get!(SyncRun, sync_run_id)
    run(sync_run, args, job)
  end

  defp run(%SyncRun{status: :running} = sync_run, args, job) do
    limit = Map.get(args, "limit")
    dry_run = Map.get(args, "dry_run", false)

    if exhausted?(sync_run.counts, limit) or elem(cursor(sync_run), 0) >= slice_count() do
      close_run(sync_run, :completed)
      :ok
    else
      process_page(sync_run, limit, dry_run, job)
    end
  end

  # At-least-once delivery means a duplicate execution of an already-closed
  # run's job is always possible; treated as a safe no-op rather than a
  # crash (queue concurrency of 1 and the facade's "one running run per
  # kind" check make it rare, not impossible).
  defp run(%SyncRun{}, _args, _job), do: :ok

  defp process_page(sync_run, limit, dry_run, job) do
    {slice_index, offset} = cursor(sync_run)
    {lower, upper} = slice_bounds(slice_index)
    page_limit = effective_page_limit(sync_run.counts, limit)

    query =
      Templates.events_page(%{lower: lower, upper: upper, limit: page_limit, offset: offset})

    case sparql_client().query(query, []) do
      {:ok, result} ->
        handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result)

      {:error, reason} ->
        handle_error(sync_run, reason, job)
    end
  end

  defp handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result) do
    {events, rejected} = EventDecoder.decode(result)
    upserted = upsert(events, dry_run)

    new_counts =
      SyncRun.merge_counts(sync_run.counts, %{
        "pages" => 1,
        "events_fetched" => length(events) + rejected,
        "events_upserted" => upserted,
        "events_rejected" => rejected
      })

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
      exhausted?(new_counts, limit) -> close_run(updated_run, :completed)
      next_slice_index >= slice_count() -> close_run(updated_run, :completed)
      true -> enqueue_next(updated_run.id, limit, dry_run)
    end

    :ok
  end

  defp handle_error(sync_run, reason, %Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    Logger.warning("ImportEvents page failed: #{inspect(reason)}")

    if attempt >= max_attempts do
      close_run(sync_run, :failed, inspect(reason))
    end

    {:error, reason}
  end

  defp upsert(_events, true), do: 0

  defp upsert(events, false) do
    {:ok, %{upserted: upserted}} = events |> Enum.map(&to_atlas_attrs/1) |> Atlas.upsert_events()
    upserted
  end

  defp to_atlas_attrs(%ExtractedEvent{} = event) do
    %{
      qid: event.qid,
      label_fr: event.label_fr,
      label_en: event.label_en,
      description_fr: event.description_fr,
      description_en: event.description_en,
      wiki_url_fr: event.wiki_url_fr,
      wiki_url_en: event.wiki_url_en,
      kind: event.kind,
      geom: event.geom,
      location_source: event.location_source,
      sitelink_count: event.sitelink_count
    }
    |> Map.merge(Event.flatten_date(event.begin, :begin))
    |> Map.merge(Event.flatten_date(event.end, :end))
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

  defp slice_bounds(slice_index) do
    width = slice_width()
    lower = slice_index * width
    {lower, lower + width}
  end

  defp slice_count, do: ceil(max_qid() / slice_width())

  defp exhausted?(_counts, nil), do: false
  defp exhausted?(counts, limit), do: Map.get(counts, "events_fetched", 0) >= limit

  defp effective_page_limit(_counts, nil), do: page_size()

  defp effective_page_limit(counts, limit) do
    remaining = limit - Map.get(counts, "events_fetched", 0)
    min(page_size(), max(remaining, 1))
  end

  defp close_run(sync_run, status, last_error \\ nil) do
    sync_run
    |> SyncRun.close_changeset(%{status: status, last_error: last_error})
    |> Repo.update!()
  end

  defp enqueue_next(sync_run_id, limit, dry_run) do
    {:ok, _job} =
      %{"sync_run_id" => sync_run_id, "limit" => limit, "dry_run" => dry_run}
      |> new()
      |> Oban.insert()

    :ok
  end

  defp sparql_client, do: Application.get_env(:amanogawa, :sparql_client)

  defp page_size, do: worker_config(:page_size, @default_page_size)
  defp slice_width, do: worker_config(:slice_width, @default_slice_width)
  defp max_qid, do: worker_config(:max_qid, @default_max_qid)

  defp worker_config(key, default) do
    :amanogawa |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
