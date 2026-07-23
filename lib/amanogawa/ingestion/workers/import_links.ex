defmodule Amanogawa.Ingestion.Workers.ImportLinks do
  @moduledoc """
  Oban worker orchestrating the Wikidata relation import: pages through the
  source QID space with `Amanogawa.Ingestion.Wikidata.Templates.
  links_page/1`, decodes each page with `Amanogawa.Ingestion.Wikidata.
  LinkDecoder`, and writes the result through `Amanogawa.Atlas.
  upsert_event_links/1` (never `Amanogawa.Atlas.EventLink` nor
  `Amanogawa.Repo` directly).

  Orchestration (one job per page, pagination plan, resumable cursor,
  error handling, `dry_run`, chaining, concurrency safeguards) mirrors
  `Amanogawa.Ingestion.Workers.ImportEvents` exactly; see that module's
  moduledoc for the rationale behind each of those choices. The only
  behavioral differences are the query (`links_page/1` instead of
  `events_page/1`), the decoder (`LinkDecoder` instead of `EventDecoder`),
  the write (`Amanogawa.Atlas.upsert_event_links/1` instead of
  `upsert_events/1`), and the counters tracked below.

  This worker is meant to run after `ImportEvents` has populated the local
  corpus (orchestrated in a later issue): run on an empty `events` table,
  it creates nothing, every candidate pair going to `links_skipped_missing`
  since neither endpoint exists locally yet. That is correct, if useless,
  behavior, not an error.

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

  require Logger

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.Wikidata.ExtractedLink
  alias Amanogawa.Ingestion.Wikidata.LinkDecoder
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
  # run's job is always possible; treated as a safe no-op (see
  # `Amanogawa.Ingestion.Workers.ImportEvents`'s equivalent clause).
  defp run(%SyncRun{}, _args, _job), do: :ok

  defp process_page(sync_run, limit, dry_run, job) do
    {slice_index, offset} = cursor(sync_run)
    {lower, upper} = slice_bounds(slice_index)
    page_limit = effective_page_limit(sync_run.counts, limit)

    query =
      Templates.links_page(%{lower: lower, upper: upper, limit: page_limit, offset: offset})

    case sparql_client().query(query, []) do
      {:ok, result} ->
        handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result)

      {:error, reason} ->
        handle_error(sync_run, reason, job)
    end
  end

  defp handle_page(sync_run, slice_index, offset, page_limit, limit, dry_run, result) do
    {links, rejected} = LinkDecoder.decode(result)
    {created, skipped_missing} = upsert(links, dry_run)

    new_counts =
      sync_run.counts
      |> SyncRun.merge_counts(%{
        "pages" => 1,
        "links_fetched" => length(result.bindings),
        "links_created" => created,
        "links_skipped_missing" => skipped_missing,
        "links_rejected" => rejected
      })
      |> merge_by_property(links)

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
    Logger.warning("ImportLinks page failed: #{inspect(reason)}")

    if attempt >= max_attempts do
      close_run(sync_run, :failed, inspect(reason))
    end

    {:error, reason}
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
  defp exhausted?(counts, limit), do: Map.get(counts, "links_fetched", 0) >= limit

  defp effective_page_limit(_counts, nil), do: page_size()

  defp effective_page_limit(counts, limit) do
    remaining = limit - Map.get(counts, "links_fetched", 0)
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
