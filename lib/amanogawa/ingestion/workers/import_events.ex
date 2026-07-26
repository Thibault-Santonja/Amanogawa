defmodule Amanogawa.Ingestion.Workers.ImportEvents do
  @moduledoc """
  Oban worker orchestrating the Wikidata event import: pages through the
  QID space with `Amanogawa.Ingestion.Wikidata.Templates.events_page/1`,
  decodes each page with `Amanogawa.Ingestion.Wikidata.EventDecoder`, and
  writes the result through `Amanogawa.Atlas.upsert_events/1` (never
  `Amanogawa.Atlas.Event` nor `Amanogawa.Repo` directly: Ingestion never
  bypasses the Atlas facade).

  All orchestration (one job per page, pagination plan, resumable cursor,
  error and crash handling, `dry_run`, chaining, concurrency safeguards)
  lives in `Amanogawa.Ingestion.Workers.PagedImport`; this module only
  provides the import-specific parts through that module's callbacks.

  ## Counters

  `events_fetched` counts every binding a page returns (each binding is
  either decoded or rejected, so `events_fetched = events_upserted +
  events_rejected` on a non-dry run); `events_rejected` tracks bindings
  dropped by `Amanogawa.Ingestion.Wikidata.EventDecoder` for data-quality
  reasons.

  ## Layered-data coexistence (issue #035)

  After every non-dry-run upsert, this worker calls
  `Amanogawa.Contributions.record_sync_divergences/1` with the SAME
  normalized attrs the page just upserted (a facade-to-facade call,
  `.claude/rules/architecture.md`: Ingestion already calls the Atlas
  facade the same way): the accepted overrides Wikidata's incoming values
  might diverge from get journalled or superseded there, never here.
  `sync_unchanged`, `sync_superseded`, `sync_conflicts_opened` and
  `sync_conflicts_refreshed` are folded into the run's counters
  alongside `events_upserted`. A `dry_run` never calls it, exactly as it
  never calls `Amanogawa.Atlas.upsert_events/1`: nothing to compare a
  divergence against when nothing was written.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  @behaviour Amanogawa.Ingestion.Workers.PagedImport

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Wikidata.EventDecoder
  alias Amanogawa.Ingestion.Wikidata.ExtractedEvent
  alias Amanogawa.Ingestion.Wikidata.Templates
  alias Amanogawa.Ingestion.Workers.PagedImport

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = job), do: PagedImport.perform(job, __MODULE__)

  @impl PagedImport
  def page_query(bounds), do: Templates.events_page(bounds)

  @impl PagedImport
  def fetched_count_key, do: "events_fetched"

  @impl PagedImport
  def apply_page(counts, result, dry_run) do
    {events, rejected} = EventDecoder.decode(result)
    {upserted, divergences} = upsert(events, dry_run)

    SyncRun.merge_counts(counts, %{
      "events_fetched" => length(events) + rejected,
      "events_upserted" => upserted,
      "events_rejected" => rejected,
      "sync_unchanged" => divergences.unchanged,
      "sync_superseded" => divergences.superseded,
      "sync_conflicts_opened" => divergences.conflicts_opened,
      "sync_conflicts_refreshed" => divergences.conflicts_refreshed
    })
  end

  defp upsert(_events, true), do: {0, empty_divergences()}

  defp upsert(events, false) do
    attrs = Enum.map(events, &to_atlas_attrs/1)
    {:ok, %{upserted: upserted}} = Atlas.upsert_events(attrs)
    divergences = Contributions.record_sync_divergences(attrs)
    {upserted, divergences}
  end

  defp empty_divergences,
    do: %{unchanged: 0, superseded: 0, conflicts_opened: 0, conflicts_refreshed: 0}

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
    |> Map.merge(Atlas.flatten_date(event.begin, :begin))
    |> Map.merge(Atlas.flatten_date(event.end, :end))
  end
end
