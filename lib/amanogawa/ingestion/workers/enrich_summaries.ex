defmodule Amanogawa.Ingestion.Workers.EnrichSummaries do
  @moduledoc """
  Oban worker orchestrating the Wikipedia summaries enrichment (#012):
  selects a small batch of events lacking a fresh extract
  (`Amanogawa.Atlas.list_events_to_enrich/1`), fetches each one's summary
  (fr prioritized, en fallback) through
  `Amanogawa.Ingestion.WikipediaClient`, and stores the result through
  `Amanogawa.Atlas.put_event_summary/2`/`mark_summary_attempt/1` (never
  `Amanogawa.Atlas.Event` nor `Amanogawa.Repo` directly: Ingestion never
  bypasses the Atlas facade).

  ## One job, one batch, implicit cursor

  Each execution of `perform/1` processes one small batch (`batch_size`,
  default 50). Unlike `Amanogawa.Ingestion.Workers.ImportEvents`, this
  worker carries no explicit resume cursor in the `SyncRun`: an event is
  selected by `list_events_to_enrich/1` precisely because it has not been
  enriched recently, so once a batch's events are written, they naturally
  drop out of the next selection. The run is resumable by construction, and
  closes itself as soon as `list_events_to_enrich/1` comes back empty.

  ## Batch lent (ADR 0003, `.claude/rules/ethics.md`)

  The `:wikipedia` Oban queue runs at concurrency 1 (one Wikipedia request
  at a time, system-wide). On top of that, each job schedules its successor
  with a delay (`inter_batch_delay_seconds`) rather than chaining
  immediately, deliberately smoothing the enrichment pace instead of
  hammering the endpoint back to back.

  ## Rate limiting

  A per-event `{:rate_limited, retry_after}` stops the batch immediately
  (no more requests fired from this job) and snoozes the job itself
  (`{:snooze, seconds}`) instead of failing it: events already written in
  this batch stay written (excluded from the next selection), the
  rate-limited event and everything after it in the batch are naturally
  retried once the job resumes, because they are still eligible.

  ## Other fetch errors and the non-progression guard

  A *permanent* per-event error (an HTTP 4xx other than 429, or a
  `:decode_error`: retrying the exact same request cannot succeed) is
  handled like a `:not_found`: `extract_fetched_at` is stamped
  (`Amanogawa.Atlas.mark_summary_attempt/1`) so the event leaves the
  selection until the cache window expires, instead of being re-selected
  and re-failed on every batch forever.

  A *transient* error (timeout, transport failure, 5xx) leaves the event
  untouched, eligible again on the next batch. To keep persistent
  transient errors from looping forever (the same events re-selected, the
  same failures, no state advancing), a batch that makes no progression at
  all (no summary stored, no attempt stamped, nothing rate-limited) closes
  the run `:failed` with an explicit `last_error`: the next selection would
  be identical, so chaining another batch could only spin.

  A crash on the job's final Oban attempt closes the run `:failed` before
  re-raising (`Amanogawa.Ingestion.Workers.RunGuard`), so no exception can
  leave an orphaned `:running` run behind.

  ## `dry_run`

  Walks the chain (selection, fetch, counting) for exactly one batch and
  only omits the `Amanogawa.Atlas.put_event_summary/2`/
  `mark_summary_attempt/1` calls, then closes the run. A single batch, not
  the whole corpus like `Amanogawa.Ingestion.Workers.ImportEvents`'
  `dry_run`: the implicit-cursor design above only ever excludes an event
  from selection once it has actually been written, so a `dry_run` that
  kept chaining would select and "preview" the exact same batch forever.
  """

  use Oban.Worker, queue: :wikipedia, max_attempts: 5

  require Logger

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.WikipediaClient
  alias Amanogawa.Ingestion.WikipediaClient.Summary
  alias Amanogawa.Ingestion.Workers.RunGuard
  alias Amanogawa.Repo

  @default_batch_size 50
  @default_inter_batch_delay_seconds 30
  @default_rate_limited_snooze_seconds 60

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()}
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id} = args} = job) do
    sync_run = Repo.get!(SyncRun, sync_run_id)
    run(sync_run, args)
  rescue
    exception ->
      RunGuard.close_failed_on_final_attempt(job, exception, __MODULE__)
      reraise exception, __STACKTRACE__
  end

  defp run(%SyncRun{status: :running} = sync_run, args) do
    limit = Map.get(args, "limit")
    dry_run = Map.get(args, "dry_run", false)
    max_age_days = Map.get(args, "max_age_days")

    if exhausted?(sync_run.counts, limit) do
      close_run(sync_run, :completed)
      :ok
    else
      events = fetch_batch(sync_run.counts, limit, max_age_days)
      process_batch(sync_run, events, limit, dry_run, max_age_days)
    end
  end

  # At-least-once delivery means a duplicate execution of an already-closed
  # run's job is always possible; treated as a safe no-op rather than a
  # crash (queue concurrency of 1 and the facade's "one running run per
  # kind" check make it rare, not impossible).
  defp run(%SyncRun{}, _args), do: :ok

  defp fetch_batch(counts, limit, max_age_days) do
    Atlas.list_events_to_enrich(
      limit: effective_batch_limit(counts, limit),
      max_age_days: max_age_days || default_max_age_days()
    )
  end

  defp process_batch(sync_run, [], _limit, _dry_run, _max_age_days) do
    close_run(sync_run, :completed)
    :ok
  end

  defp process_batch(sync_run, events, limit, dry_run, max_age_days) do
    {deltas, progressed, snoozed_for} = enrich_events(events, dry_run)

    new_counts = SyncRun.merge_counts(sync_run.counts, deltas)

    updated_run =
      sync_run
      |> SyncRun.progress_changeset(%{counts: new_counts})
      |> Repo.update!()

    cond do
      snoozed_for != nil ->
        {:snooze, snoozed_for}

      dry_run or exhausted?(new_counts, limit) ->
        close_run(updated_run, :completed)
        :ok

      not progressed ->
        # Non-progression guard (see moduledoc): every event of the batch
        # hit a transient error, nothing was written, the next selection
        # would return the exact same events. Chaining would loop forever.
        close_run(
          updated_run,
          :failed,
          "no progression in batch: #{length(events)} event(s) all failed transiently; " <>
            "the same events would be re-selected, refusing to loop"
        )

        :ok

      true ->
        enqueue_next(updated_run.id, limit, dry_run, max_age_days)
    end
  end

  # Stops at the first rate-limited event: `Enum.reduce_while/3` never fires
  # another request once the endpoint has said "slow down". `progressed`
  # tracks whether at least one event advanced the run's persistent state
  # (summary stored or attempt stamped); in dry_run mode nothing is ever
  # written, so every handled event counts as progression there (the run
  # closes after one batch anyway).
  defp enrich_events(events, dry_run) do
    Enum.reduce_while(events, {%{}, false, nil}, fn event, {deltas, progressed, nil} ->
      case enrich_event(event, dry_run) do
        {:ok, delta, event_progressed} ->
          {:cont, {SyncRun.merge_counts(deltas, delta), progressed or event_progressed, nil}}

        {:rate_limited, retry_after} ->
          {:halt, {deltas, true, retry_after || default_snooze_seconds()}}
      end
    end)
  end

  defp enrich_event(event, dry_run) do
    {lang, title} = fetch_target(event)

    case wikipedia_client().fetch_summary(lang, title) do
      {:ok, summary} ->
        unless dry_run, do: store_summary!(event, lang, summary)
        {:ok, %{"fetched" => 1, enriched_counter(lang) => 1}, true}

      {:error, :not_found} ->
        unless dry_run, do: mark_attempt!(event)
        {:ok, %{"fetched" => 1, "not_found" => 1}, true}

      {:error, {:rate_limited, retry_after}} ->
        {:rate_limited, retry_after}

      {:error, reason} ->
        handle_fetch_error(event, reason, dry_run)
    end
  end

  defp handle_fetch_error(event, reason, dry_run) do
    if permanent_error?(reason) do
      # Stamping the attempt defers the event for the whole cache window:
      # retrying an unrecoverable request every batch would only re-fail.
      Logger.warning(
        "EnrichSummaries permanent fetch failure for #{event.qid}: #{inspect(reason)}"
      )

      unless dry_run, do: mark_attempt!(event)
      {:ok, %{"fetched" => 1, "errors" => 1}, true}
    else
      Logger.warning("EnrichSummaries fetch failed for #{event.qid}: #{inspect(reason)}")
      {:ok, %{"fetched" => 1, "errors" => 1}, dry_run}
    end
  end

  # A 4xx (other than 429, surfaced as {:rate_limited, _} upstream) or an
  # undecodable body cannot succeed on retry; everything else (timeout,
  # transport, 5xx) legitimately can.
  defp permanent_error?({:http_error, status}) when status in 400..499 and status != 429,
    do: true

  defp permanent_error?({:decode_error, _reason}), do: true
  defp permanent_error?(_reason), do: false

  # fr is prioritized over en (ADR 0003); an event selected by
  # `Amanogawa.Atlas.list_events_to_enrich/1` always has at least one of the
  # two. Matched structurally (never on the struct name): Ingestion depends
  # on the Atlas facade's contract, not on its internal schema module.
  defp fetch_target(%{wiki_url_fr: url}) when is_binary(url),
    do: {:fr, WikipediaClient.title_from_wiki_url(url)}

  defp fetch_target(%{wiki_url_en: url}) when is_binary(url),
    do: {:en, WikipediaClient.title_from_wiki_url(url)}

  defp store_summary!(event, lang, %Summary{} = summary) do
    {:ok, _event} =
      Atlas.put_event_summary(event, %{
        lang: lang,
        extract: summary.extract,
        thumbnail_url: summary.thumbnail_url,
        article_url: summary.article_url
      })

    :ok
  end

  defp mark_attempt!(event) do
    {:ok, _event} = Atlas.mark_summary_attempt(event)
    :ok
  end

  defp enriched_counter(:fr), do: "enriched_fr"
  defp enriched_counter(:en), do: "enriched_en"

  defp exhausted?(_counts, nil), do: false
  defp exhausted?(counts, limit), do: Map.get(counts, "fetched", 0) >= limit

  defp effective_batch_limit(_counts, nil), do: batch_size()

  defp effective_batch_limit(counts, limit) do
    remaining = limit - Map.get(counts, "fetched", 0)
    min(batch_size(), max(remaining, 1))
  end

  defp close_run(sync_run, status, last_error \\ nil) do
    sync_run
    |> SyncRun.close_changeset(%{status: status, last_error: last_error})
    |> Repo.update!()
  end

  defp enqueue_next(sync_run_id, limit, dry_run, max_age_days) do
    {:ok, _job} =
      %{
        "sync_run_id" => sync_run_id,
        "limit" => limit,
        "dry_run" => dry_run,
        "max_age_days" => max_age_days
      }
      |> new(schedule_in: inter_batch_delay_seconds())
      |> Oban.insert()

    :ok
  end

  defp wikipedia_client, do: Application.get_env(:amanogawa, :wikipedia_client)
  defp default_max_age_days, do: Application.get_env(:amanogawa, :summary_max_age_days, 30)

  defp batch_size, do: worker_config(:batch_size, @default_batch_size)

  defp inter_batch_delay_seconds,
    do: worker_config(:inter_batch_delay_seconds, @default_inter_batch_delay_seconds)

  defp default_snooze_seconds,
    do: worker_config(:default_snooze_seconds, @default_rate_limited_snooze_seconds)

  defp worker_config(key, default) do
    :amanogawa |> Application.get_env(__MODULE__, []) |> Keyword.get(key, default)
  end
end
