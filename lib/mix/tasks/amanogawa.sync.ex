defmodule Mix.Tasks.Amanogawa.Sync do
  @shortdoc "Runs a Wikidata/Wikipedia ingestion sync (events, links, summaries, or all)"

  @moduledoc """
  Starts (or, for `all`, chains) one or more ingestion pipelines through
  the `Amanogawa.Ingestion` facade, waits for each to close, and reports
  its outcome.

  This task performs no orchestration of its own: it validates
  arguments, starts the application, calls into `Amanogawa.Ingestion`,
  and displays progress read back from `Amanogawa.Ingestion.SyncRun`
  (`Amanogawa.Ingestion.await_run/2`). The Oban Cron monthly schedule
  (`config/config.exs`, `Amanogawa.Ingestion.Workers.ScheduledSync`)
  calls the exact same facade functions, so a manual run through this
  task and a scheduled run give the same guarantees (tracing,
  idempotence, resume).

  See `docs/ops/sync.md` for the full operational runbook (first import,
  expected volumetry, monitoring, troubleshooting).

  ## Usage

      mix amanogawa.sync TARGET [--limit N] [--dry-run]

  `TARGET` (required, first argument):

    * `events` - imports Wikidata events (`Amanogawa.Ingestion.start_events_import/1`)
    * `links` - imports Wikidata event relations (`Amanogawa.Ingestion.start_links_import/1`)
    * `summaries` - enriches events with Wikipedia summaries (`Amanogawa.Ingestion.start_summaries_enrichment/1`)
    * `all` - runs `events`, then `links`, then `summaries`, each step
      waiting for the previous one to close `:completed` before
      starting; stops immediately, with a non-zero exit code, if any
      step closes `:failed`

  ## Options

    * `--limit N` - caps the number of items processed by the run (see
      the corresponding `Amanogawa.Ingestion.start_*` function's
      `:limit` documentation for what "item" means for that pipeline);
      `--limit 0` starts and immediately closes an empty, `:completed`
      run
    * `--dry-run` - walks the full pipeline (query, decode, counting)
      but never writes to `Amanogawa.Atlas`; counters are still reported

  ## Examples

  First production import, one pipeline at a time (recommended order,
  see `docs/ops/sync.md`):

      mix amanogawa.sync events
      mix amanogawa.sync links
      mix amanogawa.sync summaries

  Or chained:

      mix amanogawa.sync all

  A bounded dry run on a development machine:

      mix amanogawa.sync events --limit 100 --dry-run

  ## Exit status

  `0` on success (every requested step closed `:completed`); non-zero
  (via `Mix.raise/1`) on an argument error, a run already in progress
  for the target kind, a step closing `:failed`, or a wait timing out.

  ## Resuming a failed run

  A `:failed` run is not retried automatically. The failure message
  printed by this task includes the exact `iex -S mix` snippet to
  resume it: `Amanogawa.Ingestion.resume_events_import/1` and
  `resume_links_import/1` reopen a failed run from its cursor;
  `summaries` has no separate resume function; its implicit-cursor
  design (`Amanogawa.Ingestion.Workers.EnrichSummaries`) means
  re-running `mix amanogawa.sync summaries` naturally skips whatever was
  already enriched.
  """

  use Mix.Task

  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SyncRun

  @usage """
  Usage: mix amanogawa.sync TARGET [--limit N] [--dry-run]

  TARGET: events | links | summaries | all
  """

  # Generous enough to cover a full, un-limited summaries run: the
  # inter-batch delay alone (30s default, .claude/rules/ethics.md's
  # "batch lent") can stretch that pipeline over several hours.
  @await_timeout_ms :timer.hours(24)
  # Coarse enough to keep a multi-hour run's terminal output readable.
  @progress_poll_interval_ms :timer.seconds(30)

  @queue_by_kind %{events: :ingestion, links: :ingestion, summaries: :wikipedia}

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {target, opts} = parse_args!(argv)
    kinds = if target == :all, do: [:events, :links, :summaries], else: [target]

    run_chain(kinds, opts)
  end

  defp run_chain(kinds, opts) do
    kinds
    |> Enum.reduce_while(:ok, fn kind, :ok ->
      case run_step(kind, opts) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      :ok -> :ok
      :error -> Mix.raise("Sync stopped: see the failure reported above.")
    end
  end

  defp run_step(kind, opts) do
    case start_kind(kind, opts) do
      {:error, :already_running} ->
        Mix.raise("""
        A #{kind} sync is already running: refusing to start a second one.
        Check its progress with `Amanogawa.Ingestion.last_sync_run(:#{kind})` \
        from `iex -S mix`, or in `ingestion.sync_runs`, and wait for it to finish.
        """)

      {:ok, sync_run} ->
        Mix.shell().info("[#{kind}] started sync_run #{sync_run.id}")
        drain_if_manual(kind)
        await_and_report(kind, sync_run)
    end
  end

  defp start_kind(:events, opts), do: Ingestion.start_events_import(opts)
  defp start_kind(:links, opts), do: Ingestion.start_links_import(opts)
  defp start_kind(:summaries, opts), do: Ingestion.start_summaries_enrichment(opts)

  # Oban runs in manual testing mode only in config/test.exs: real
  # dev/prod runs let the normal Oban queue supervisors process jobs in
  # the background while `await_and_report/2` polls. In manual mode
  # nothing consumes the queue on its own, so this drains it
  # synchronously in-process instead. `with_recursion` picks up the
  # self-chained follow-up jobs `Amanogawa.Ingestion.Workers.ImportEvents`/
  # `ImportLinks` enqueue; `with_scheduled` picks up `EnrichSummaries`'
  # delayed batches regardless of their `scheduled_at`.
  defp drain_if_manual(kind) do
    if Application.get_env(:amanogawa, Oban)[:testing] == :manual do
      Oban.drain_queue(
        queue: Map.fetch!(@queue_by_kind, kind),
        with_recursion: true,
        with_scheduled: true
      )
    end
  end

  defp await_and_report(kind, sync_run) do
    result =
      Ingestion.await_run(sync_run,
        timeout_ms: @await_timeout_ms,
        poll_interval_ms: @progress_poll_interval_ms,
        on_progress: &print_progress(kind, &1)
      )

    case result do
      {:ok, %SyncRun{status: :completed} = run} ->
        print_summary(kind, run)
        :ok

      {:ok, %SyncRun{status: :failed} = run} ->
        print_failure(kind, run)
        :error

      {:error, :timeout} ->
        Mix.raise(
          "[#{kind}] timed out after #{inspect(@await_timeout_ms)}ms waiting for sync_run " <>
            "#{sync_run.id} to close. It may still be running: check `ingestion.sync_runs`."
        )
    end
  end

  defp print_progress(kind, %SyncRun{status: :running} = run) do
    Mix.shell().info("[#{kind}] " <> format_counts(run.counts) <> format_cursor(run.cursor))
  end

  defp print_progress(_kind, %SyncRun{}), do: :ok

  defp print_summary(kind, %SyncRun{} = run) do
    Mix.shell().info(
      "[#{kind}] completed in #{format_duration(run)}: " <> format_counts(run.counts)
    )
  end

  defp print_failure(kind, %SyncRun{} = run) do
    Mix.shell().error("""
    [#{kind}] failed after #{format_duration(run)}: #{run.last_error}
    Counters at failure: #{format_counts(run.counts)}

    Resume from `iex -S mix`:
        #{resume_snippet(kind, run.id)}
    """)
  end

  defp resume_snippet(:events, id) do
    "Amanogawa.Ingestion.resume_events_import(Amanogawa.Ingestion.get_sync_run(#{inspect(id)}))"
  end

  defp resume_snippet(:links, id) do
    "Amanogawa.Ingestion.resume_links_import(Amanogawa.Ingestion.get_sync_run(#{inspect(id)}))"
  end

  defp resume_snippet(:summaries, _id) do
    "mix amanogawa.sync summaries (re-running skips events already enriched)"
  end

  # `inspect/1` rather than string interpolation: most counters are plain
  # integers, but `Amanogawa.Ingestion.Workers.ImportLinks`' `by_property`
  # counter is a nested map (no `String.Chars` implementation).
  defp format_counts(counts) do
    counts
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
  end

  defp format_cursor(%{"slice_index" => slice_index, "offset" => offset}),
    do: " (slice #{slice_index}, offset #{offset})"

  defp format_cursor(_other), do: ""

  defp format_duration(%SyncRun{started_at: started_at, finished_at: finished_at}) do
    seconds = DateTime.diff(finished_at, started_at, :second)
    minutes = div(seconds, 60)
    "#{minutes}m#{rem(seconds, 60)}s"
  end

  defp parse_args!(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: [limit: :integer, dry_run: :boolean])

    unless invalid == [] do
      names = Enum.map_join(invalid, ", ", fn {key, _value} -> key end)
      Mix.raise("Invalid option(s): #{names}\n\n#{@usage}")
    end

    target = parse_target!(args)
    limit = parse_limit!(Keyword.get(opts, :limit))

    {target, [limit: limit, dry_run: Keyword.get(opts, :dry_run, false)]}
  end

  defp parse_target!(["events"]), do: :events
  defp parse_target!(["links"]), do: :links
  defp parse_target!(["summaries"]), do: :summaries
  defp parse_target!(["all"]), do: :all
  defp parse_target!([]), do: Mix.raise("Missing target.\n\n#{@usage}")

  defp parse_target!([other]) do
    Mix.raise("Unknown target #{inspect(other)}.\n\n#{@usage}")
  end

  defp parse_target!(many) do
    Mix.raise("Too many arguments: #{inspect(many)}.\n\n#{@usage}")
  end

  defp parse_limit!(nil), do: nil

  defp parse_limit!(limit) when limit >= 0, do: limit

  defp parse_limit!(limit) do
    Mix.raise("--limit must be a non-negative integer, got #{limit}.\n\n#{@usage}")
  end
end
