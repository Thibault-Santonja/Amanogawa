defmodule Amanogawa.Atlas do
  @moduledoc """
  Public API of the Atlas bounded context: the read model served to the UI
  (historical events and the typed links between them).

  Ingestion writes into Atlas exclusively through this facade: never by
  calling `Amanogawa.Atlas.Event`/`Amanogawa.Atlas.EventLink` internals or
  `Amanogawa.Repo` directly from another context.
  """

  import Ecto.Query

  alias Amanogawa.Atlas.Event
  alias Amanogawa.Atlas.EventLink
  alias Amanogawa.Repo

  # PostgreSQL allows at most 65535 bound parameters per statement; with
  # around twenty columns per event row, 500 rows per batch stays
  # comfortably under that limit.
  @max_batch_size 500

  # Default `list_events_to_enrich/1` batch size, overridable per call.
  @default_enrich_batch_size 50

  @wikipedia_license "CC BY-SA 4.0"

  # Columns replaced on conflict when upserting events from Wikidata.
  # Deliberately excludes :id, :inserted_at, :qid (the conflict target) and
  # the Wikipedia enrichment columns (extract_fr, extract_en, thumbnail_url,
  # extract_attribution, extract_fetched_at, filled by #012): a Wikidata
  # upsert must never erase enrichment data written by
  # `Amanogawa.Ingestion.Workers.EnrichSummaries`.
  @wikidata_columns [
    :label_fr,
    :label_en,
    :description_fr,
    :description_en,
    :wiki_url_fr,
    :wiki_url_en,
    :kind,
    :begin_year,
    :begin_month,
    :begin_day,
    :begin_precision,
    :begin_calendar,
    :end_year,
    :end_month,
    :end_day,
    :end_precision,
    :end_calendar,
    :geom,
    :location_source,
    :sitelink_count,
    :updated_at
  ]

  @doc """
  Upserts a batch of normalized event attribute maps (flat, including
  `:qid`), keyed by `:qid`.

  Idempotent: replaying the same batch leaves both the row count and every
  business column unchanged. Rows are inserted in chunks of
  #{@max_batch_size} to stay under PostgreSQL's parameter limit. Existing
  enrichment columns (Wikipedia extracts) are preserved: see
  `@wikidata_columns`.

  Rows are deduplicated on `:qid` (first occurrence wins) before insertion:
  PostgreSQL's `ON CONFLICT DO UPDATE` refuses to affect the same row twice
  within one statement, so a page containing the same QID twice (a hostile
  or buggy endpoint) must never crash the batch.

  `insert_all/3` bypasses changesets by design; callers are expected to
  hand in already-normalized data (as produced by the ingestion SPARQL
  decoder). Database constraints (QID format is not enforced here, only
  uniqueness) remain the safety net.
  """
  @spec upsert_events([map()]) :: {:ok, %{upserted: non_neg_integer()}}
  def upsert_events(events) when is_list(events) do
    upserted =
      events
      |> Enum.map(&prepare_event_row/1)
      |> Enum.uniq_by(& &1.qid)
      |> Enum.chunk_every(@max_batch_size)
      |> Enum.reduce(0, &(insert_event_batch(&1) + &2))

    {:ok, %{upserted: upserted}}
  end

  @doc """
  Upserts typed links between events, given as a list of
  `%{source_qid: qid, target_qid: qid, type: type}` maps.

  QIDs are resolved to internal ids in a single query; pairs where either
  QID is not (yet) known locally are silently skipped, since ingestion
  routinely processes events before some of their relations exist locally.
  Insertion is idempotent: the unique `(source_id, target_id, type)` index
  combined with `on_conflict: :nothing` means replaying a batch creates no
  duplicate. Rows are also deduplicated on `(source_id, target_id, type)`
  within the batch itself, so the `created` count stays exact when a page
  repeats a pair.
  """
  @spec upsert_event_links([
          %{source_qid: String.t(), target_qid: String.t(), type: EventLink.link_type()}
        ]) ::
          {:ok, %{created: non_neg_integer(), skipped_missing: non_neg_integer()}}
  def upsert_event_links(links) when is_list(links) do
    qids = links |> Enum.flat_map(&[&1.source_qid, &1.target_qid]) |> Enum.uniq()
    ids_by_qid = event_ids_by_qids(qids)

    {rows, skipped} = build_link_rows(links, ids_by_qid)

    created =
      rows
      |> Enum.chunk_every(@max_batch_size)
      |> Enum.reduce(0, &(insert_link_batch(&1) + &2))

    {:ok, %{created: created, skipped_missing: skipped}}
  end

  @doc "Fetches an event by its Wikidata QID, or `nil` if unknown locally."
  @spec get_event_by_qid(String.t()) :: Event.t() | nil
  def get_event_by_qid(qid) do
    Repo.get_by(Event, qid: qid)
  end

  @doc """
  Flattens an `Amanogawa.HistoricalDate` (or `nil`) into `begin_*`/`end_*`
  attributes for `upsert_events/1` rows. Delegates to
  `Amanogawa.Atlas.Event.flatten_date/2`, exposed here so other contexts
  (Ingestion) never reach into Atlas internals.
  """
  defdelegate flatten_date(date, group), to: Event

  @doc "Maps every given QID known locally to its internal id."
  @spec event_ids_by_qids([String.t()]) :: %{String.t() => Ecto.UUID.t()}
  def event_ids_by_qids(qids) when is_list(qids) do
    Event
    |> where([e], e.qid in ^qids)
    |> select([e], {e.qid, e.id})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Counts events. Used by tests and sync metrics."
  @spec count_events() :: non_neg_integer()
  def count_events, do: Repo.aggregate(Event, :count)

  @doc "Counts event links. Used by tests and sync metrics."
  @spec count_event_links() :: non_neg_integer()
  def count_event_links, do: Repo.aggregate(EventLink, :count)

  @doc """
  Lists events eligible for Wikipedia enrichment (#012): at least one
  known article (`wiki_url_fr` or `wiki_url_en`) and never fetched, or
  fetched more than `:max_age_days` ago. Ordered by `sitelink_count`
  descending, so the most visible events are enriched first when a run is
  interrupted.

  `opts`:

    * `:limit` - max events returned, default #{@default_enrich_batch_size}.
    * `:max_age_days` - cache freshness window, default
      `Application.get_env(:amanogawa, :summary_max_age_days, 30)`.
  """
  @spec list_events_to_enrich(keyword()) :: [Event.t()]
  def list_events_to_enrich(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_enrich_batch_size)
    threshold = DateTime.add(utc_now(), -max_age_days(opts), :day)

    Event
    |> where([e], not is_nil(e.wiki_url_fr) or not is_nil(e.wiki_url_en))
    |> where([e], is_nil(e.extract_fetched_at) or e.extract_fetched_at < ^threshold)
    |> order_by([e], desc: e.sitelink_count)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Stores a fetched Wikipedia summary on `event`: `extract_fr` or
  `extract_en` depending on `attrs.lang`, `thumbnail_url`,
  `extract_attribution` (CC BY-SA 4.0: article URL, license, language) and
  `extract_fetched_at` (now).

  `attrs` is the small enrichment-specific map
  `Amanogawa.Ingestion.Workers.EnrichSummaries` builds from a
  `Amanogawa.Ingestion.WikipediaClient.Summary`, deliberately not the
  `Summary` struct itself: Atlas never depends on another context's
  internal types (`.claude/rules/architecture.md`). Required keys:
  `:lang` (`:fr` or `:en`), `:extract`, `:article_url`; `:thumbnail_url` is
  optional (`nil` when the article has no image).
  """
  @spec put_event_summary(Event.t(), map()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def put_event_summary(
        %Event{} = event,
        %{lang: lang, extract: extract, article_url: article_url} = attrs
      )
      when lang in [:fr, :en] do
    changeset_attrs =
      %{
        thumbnail_url: Map.get(attrs, :thumbnail_url),
        extract_attribution: %{
          "article_url" => article_url,
          "license" => @wikipedia_license,
          "lang" => Atom.to_string(lang)
        },
        extract_fetched_at: utc_now()
      }
      |> Map.put(extract_field(lang), extract)

    event
    |> Event.summary_changeset(changeset_attrs)
    |> Repo.update()
  end

  @doc """
  Marks a Wikipedia enrichment attempt on `event` without storing an
  extract: stamps `extract_fetched_at` alone. Used for a `:not_found`
  article, so the cache stops retrying it before `:max_age_days` expires
  (points d'attention #012: without this, the worker would retry the same
  missing articles on every run).
  """
  @spec mark_summary_attempt(Event.t()) :: {:ok, Event.t()} | {:error, Ecto.Changeset.t()}
  def mark_summary_attempt(%Event{} = event) do
    event
    |> Event.summary_changeset(%{extract_fetched_at: utc_now()})
    |> Repo.update()
  end

  defp max_age_days(opts) do
    Keyword.get(opts, :max_age_days) || Application.get_env(:amanogawa, :summary_max_age_days, 30)
  end

  defp extract_field(:fr), do: :extract_fr
  defp extract_field(:en), do: :extract_en

  defp insert_event_batch(batch) do
    {count, _} =
      Repo.insert_all(Event, batch,
        on_conflict: {:replace, @wikidata_columns},
        conflict_target: :qid
      )

    count
  end

  defp insert_link_batch(batch) do
    {count, _} = Repo.insert_all(EventLink, batch, on_conflict: :nothing)
    count
  end

  defp build_link_rows(links, ids_by_qid) do
    now = utc_now()

    {rows, skipped} =
      Enum.reduce(links, {[], 0}, fn %{source_qid: source_qid, target_qid: target_qid, type: type},
                                     {rows, skipped} ->
        with {:ok, source_id} <- Map.fetch(ids_by_qid, source_qid),
             {:ok, target_id} <- Map.fetch(ids_by_qid, target_qid) do
          row = %{
            id: Ecto.UUID.generate(version: 7),
            source_id: source_id,
            target_id: target_id,
            type: type,
            inserted_at: now,
            updated_at: now
          }

          {[row | rows], skipped}
        else
          :error -> {rows, skipped + 1}
        end
      end)

    rows =
      rows
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.source_id, &1.target_id, &1.type})

    {rows, skipped}
  end

  defp prepare_event_row(attrs) do
    now = utc_now()

    attrs
    |> Map.new(fn {key, value} -> {atom_key(key), value} end)
    |> Map.put_new_lazy(:id, fn -> Ecto.UUID.generate(version: 7) end)
    |> Map.put_new(:inserted_at, now)
    |> Map.put_new(:updated_at, now)
  end

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_existing_atom(key)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
