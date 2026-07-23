defmodule Amanogawa.Ingestion.Workers.ScheduledSync do
  @moduledoc """
  Oban Cron entry point for the monthly ingestion schedule (#013, ADR
  0003). `Oban.Plugins.Cron` can only target an `Oban.Worker`, so this
  tiny worker is the bridge between a cron schedule and a pipeline: it
  starts a run through `Amanogawa.Ingestion` (the exact same facade
  function the mix task calls for a manual run), never `Amanogawa.
  Ingestion.Workers.ImportEvents`/`ImportLinks`/`EnrichSummaries`
  directly. This keeps the cron path and the manual path sharing one
  orchestration (SyncRun creation, refusal of a second concurrent run of
  the same kind, resumability) instead of duplicating any of it here.

  `args["kind"]` selects the pipeline: `"events"`, `"links"`, or
  `"summaries"` (see `config/config.exs`'s `Oban.Plugins.Cron` crontab).

  ## Overlap

  `Amanogawa.Ingestion.start_events_import/1` (and its `:links`/
  `:summaries` counterparts) refuse to start a second concurrent run of
  the same kind, returning `{:error, :already_running}`. A cron tick
  landing on top of a still-running previous month's sync is not an
  error worth retrying or alerting on: it is treated as a no-op here,
  and the overlap is visible in `ingestion.sync_runs` as a missing new
  row for that month rather than as a job failure.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 1

  alias Amanogawa.Ingestion

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"kind" => "events"}}), do: start(Ingestion.start_events_import())
  def perform(%Oban.Job{args: %{"kind" => "links"}}), do: start(Ingestion.start_links_import())

  def perform(%Oban.Job{args: %{"kind" => "summaries"}}),
    do: start(Ingestion.start_summaries_enrichment())

  defp start({:ok, _sync_run}), do: :ok
  defp start({:error, :already_running}), do: :ok
end
