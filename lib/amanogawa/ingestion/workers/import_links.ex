defmodule Amanogawa.Ingestion.Workers.ImportLinks do
  @moduledoc """
  Oban worker orchestrating the Wikidata relation import: pages through the
  source QID space with `Amanogawa.Ingestion.Wikidata.Templates.
  links_page/1`, decodes each page with `Amanogawa.Ingestion.Wikidata.
  LinkDecoder`, and writes the result through `Amanogawa.Atlas.
  upsert_event_links/1` (never `Amanogawa.Atlas.EventLink` nor
  `Amanogawa.Repo` directly).

  All orchestration (one job per page, pagination plan, resumable cursor,
  error and crash handling, `dry_run`, chaining, concurrency safeguards)
  lives in `Amanogawa.Ingestion.Workers.PagedImport`; this module only
  provides the relation-specific parts through that module's callbacks.

  This worker is meant to run after `ImportEvents` has populated the local
  corpus: run on an empty `events` table, it creates nothing, every
  candidate pair going to `links_skipped_missing` since neither endpoint
  exists locally yet. That is correct, if useless, behavior, not an error.

  ## Counters

  `links_fetched` counts every binding a page returns, exactly like the
  page's raw size (`length(result.bindings)`). `Amanogawa.Ingestion.
  Wikidata.LinkDecoder.decode/1` both rejects invalid bindings and
  deduplicates symmetric `P155`/`P156` declarations before a page is
  written, so `links_fetched` can be, and routinely is, greater than
  `links_created + links_skipped_missing + links_rejected`: the gap is
  exactly the number of duplicate declarations a page collapsed. This is
  expected, not a discrepancy to chase down.

  `by_property` breaks `links_created + links_skipped_missing` down by the
  Wikidata property each surviving (deduplicated) link was decoded from.
  When a pair is declared symmetrically through two different properties
  (`P155` on one side, `P156` on the other), the count attributes the
  whole pair to whichever property `Amanogawa.Ingestion.Wikidata.
  LinkDecoder` happened to encounter first in the page: an approximation,
  acceptable since the breakdown is a coverage metric, not an audit trail.
  """

  use Oban.Worker, queue: :ingestion, max_attempts: 5

  @behaviour Amanogawa.Ingestion.Workers.PagedImport

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Wikidata.ExtractedLink
  alias Amanogawa.Ingestion.Wikidata.LinkDecoder
  alias Amanogawa.Ingestion.Wikidata.Templates
  alias Amanogawa.Ingestion.Workers.PagedImport

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{} = job), do: PagedImport.perform(job, __MODULE__)

  @impl PagedImport
  def page_query(bounds), do: Templates.links_page(bounds)

  @impl PagedImport
  def fetched_count_key, do: "links_fetched"

  @impl PagedImport
  def apply_page(counts, result, dry_run) do
    {links, rejected} = LinkDecoder.decode(result)
    {created, skipped_missing} = upsert(links, dry_run)

    counts
    |> SyncRun.merge_counts(%{
      "links_fetched" => length(result.bindings),
      "links_created" => created,
      "links_skipped_missing" => skipped_missing,
      "links_rejected" => rejected
    })
    |> merge_by_property(links)
  end

  defp upsert(_links, true), do: {0, 0}

  defp upsert(links, false) do
    {:ok, %{created: created, skipped_missing: skipped_missing}} =
      links |> Enum.map(&to_atlas_attrs/1) |> Atlas.upsert_event_links()

    {created, skipped_missing}
  end

  defp to_atlas_attrs(%ExtractedLink{} = link) do
    %{source_qid: link.source_qid, target_qid: link.target_qid, type: link.type}
  end

  defp merge_by_property(counts, links) do
    deltas = Enum.frequencies_by(links, & &1.property)
    current = Map.get(counts, "by_property", %{})
    merged = Map.merge(current, deltas, fn _property, existing, delta -> existing + delta end)
    Map.put(counts, "by_property", merged)
  end
end
