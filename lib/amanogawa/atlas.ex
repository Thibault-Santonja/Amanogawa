defmodule Amanogawa.Atlas do
  @moduledoc """
  Public API of the Atlas bounded context: the read model served to the UI
  (historical events, the typed links between them, and the historical
  borders/"zones of influence" of political entities, ADR 0004).

  Ingestion writes into Atlas exclusively through this facade: never by
  calling `Amanogawa.Atlas.Event`/`Amanogawa.Atlas.EventLink` internals or
  `Amanogawa.Repo` directly from another context.
  """

  import Ecto.Changeset, only: [add_error: 3]
  import Ecto.Query

  alias Amanogawa.Atlas.Border
  alias Amanogawa.Atlas.BorderQueries
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Atlas.EventLink
  alias Amanogawa.Atlas.EventQueries
  alias Amanogawa.Atlas.Polity
  alias Amanogawa.Atlas.PolityColor
  alias Amanogawa.Atlas.TimeScale
  alias Amanogawa.Repo
  alias Amanogawa.WikimediaUrl

  # PostgreSQL allows at most 65535 bound parameters per statement; with
  # around twenty columns per event row, 500 rows per batch stays
  # comfortably under that limit.
  @max_batch_size 500

  # `Amanogawa.Atlas.BorderQueries.insert_batch/3` binds 10 parameters total
  # (7 arrays plus 3 scalars), each array holding one element per row: a
  # far smaller per-row footprint than the parameter *count* limit that
  # bounds `@max_batch_size` above, so this is sized instead for the
  # geometry pipeline's per-batch SQL round trip (ST_MakeValid,
  # ST_SimplifyPreserveTopology twice) to stay a reasonable single
  # statement, not for a parameter ceiling.
  @border_batch_size 200

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

  @doc """
  Lists events for the map viewport as a GeoJSON `FeatureCollection`
  (issue #014, ADR 0007): `opts` is the normalized output of
  `AmanogawaWeb.Params.EventsQuery.parse/1` (bbox envelopes, `from`/`to`
  year window, `limit`), already bounded server-side by the caller.

  Read-only and side-effect free. The query itself, including every
  PostGIS fragment, is centralized in `Amanogawa.Atlas.EventQueries`; this
  function only shapes the result into GeoJSON, the boundary where
  PostGIS geometry becomes wire format (`.claude/rules/geo-temporal.md`:
  "convert to GeoJSON only at the web edge").
  """
  @spec list_events_geojson(EventQueries.opts()) :: map()
  def list_events_geojson(opts) do
    features =
      opts
      |> EventQueries.list_events()
      |> Enum.map(&event_row_to_feature/1)

    %{"type" => "FeatureCollection", "features" => features}
  end

  @doc """
  Builds the timeline density histogram (issue #020):
  `%{from:, to:, buckets:}` (`opts`, already validated and bounded by
  `AmanogawaWeb.Params.HistogramQuery.parse/1`) mapped to
  `{"from" => ..., "to" => ..., "buckets" => [%{"from" => y0, "to" => y1,
  "count" => n}, ...]}`, a dense list (`opts.buckets` entries, empty
  buckets included with `count: 0`), bucket boundaries aligned on
  `Amanogawa.Atlas.TimeScale`'s symlog position (equal-width in position
  space, not in years).

  The scale used is always `TimeScale.default/0`: the histogram, the axis
  ticks (#019), and the map's temporal filter all read the same default
  domain, so a caller never has to pass its own `TimeScale` here. Bucket
  edges come from `Amanogawa.Atlas.EventQueries.bucket_edges/1`, the
  single definition also used by the SQL aggregation
  (`Amanogawa.Atlas.EventQueries.histogram_counts/1`), so the counts and
  the announced integer edges agree by construction (F04 quality finding
  m5): the requested `opts.from`/`opts.to` are exact at the extremes, and
  interior edges are `TimeScale.year/2` at equally spaced positions.
  """
  @spec event_histogram(%{from: integer(), to: integer(), buckets: pos_integer()}) :: map()
  def event_histogram(%{from: from, to: to, buckets: buckets}) do
    opts = %{from: from, to: to, buckets: buckets, scale: TimeScale.default()}
    counts = EventQueries.histogram_counts(opts)

    %{
      "from" => from,
      "to" => to,
      "buckets" => bucket_list(opts, counts)
    }
  end

  @doc """
  Formats an astronomical year as a timeline axis label (issue #020).
  Delegates to `Amanogawa.Atlas.TimeScale.Format.format_axis_year/3`
  (`templates` optional, French defaults; localized templates come from
  the web layer, `AmanogawaWeb.TimelineI18n`), exposed here so callers
  (the timeline hook's server-rendered counterparts, future components)
  only ever depend on `Amanogawa.Atlas`'s public API, never reach into
  `Amanogawa.Atlas.TimeScale.Format` directly.
  """
  defdelegate format_axis_year(year, step), to: TimeScale.Format
  defdelegate format_axis_year(year, step, templates), to: TimeScale.Format

  @doc "Fetches an event by its Wikidata QID, or `nil` if unknown locally."
  @spec get_event_by_qid(String.t()) :: Event.t() | nil
  def get_event_by_qid(qid) do
    Repo.get_by(Event, qid: qid)
  end

  @doc """
  Fetches the hover card / summary of `qid` (issue #016): `{:ok, summary}`
  with `qid`, `label` (fr, falling back to en), `extract` (fr, falling back
  to en, plain text as stored by #012, `nil` when neither exists yet),
  `thumbnail_url`, `wiki_url` (fr, falling back to en), `extract_language`
  (`"fr"` or `"en"`, `nil` alongside a `nil` extract) and `fetched_at` (the
  attribution timestamp), or `{:error, :not_found}` for an unknown QID.

  Format validation of `qid` is the caller's responsibility
  (`AmanogawaWeb.Params.EventId`, `.claude/rules/security.md`): this
  function only looks the QID up, it never raises on a malformed one.
  """
  @spec get_event_summary(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_event_summary(qid) do
    case get_event_by_qid(qid) do
      nil -> {:error, :not_found}
      event -> {:ok, event_summary(event)}
    end
  end

  @doc """
  Lists the typed relations of `qid` as a GeoJSON `FeatureCollection`
  (issue #017): `{:error, :not_found}` for an unknown QID, otherwise
  `{:ok, feature_collection}` with one `LineString` feature per relation
  whose two endpoints both carry a geometry, ordered from `qid` to the
  related event.

  An event known locally but without its own geometry yields an empty
  collection rather than an error: no line can be anchored without a
  starting point, but the event itself is not "unknown". The query
  (including the source/target join and the `geom IS NOT NULL` filter on
  each side) lives in `Amanogawa.Atlas.EventQueries`, this function only
  shapes the result into GeoJSON, the boundary where PostGIS geometry
  becomes wire format (`.claude/rules/geo-temporal.md`).
  """
  @spec list_event_links_geojson(String.t()) :: {:ok, map()} | {:error, :not_found}
  def list_event_links_geojson(qid) do
    case get_event_by_qid(qid) do
      nil -> {:error, :not_found}
      event -> {:ok, event_links_feature_collection(event)}
    end
  end

  @doc """
  Flattens an `Amanogawa.HistoricalDate` (or `nil`) into `begin_*`/`end_*`
  attributes for `upsert_events/1` rows. Delegates to
  `Amanogawa.Atlas.Event.flatten_date/2`, exposed here so other contexts
  (Ingestion) never reach into Atlas internals.
  """
  defdelegate flatten_date(date, group), to: Event

  @doc """
  Upserts a `Amanogawa.Atlas.Polity` keyed by its natural key `(name,
  source)` (issue #023): a fresh row is inserted, or an existing one has
  its `from_year`/`to_year` replaced, so re-running an import updates a
  polity's known existence span without duplicating the row or touching
  its id (borders elsewhere reference that id by foreign key).

  `attrs`: `:name`, `:source` (required), `:from_year`, `:to_year`
  (optional, the entity's own attested existence span). The conflict
  update is targeted: an upsert carrying `nil` for `from_year`/`to_year`
  (the common case, `Amanogawa.Ingestion.Borders.Importer` never knows an
  entity's overall span) preserves whatever non-nil span the existing row
  already carries (`COALESCE(EXCLUDED..., current)`), instead of erasing
  it (F05 quality finding).
  """
  @spec upsert_polity(map()) :: {:ok, Polity.t()} | {:error, Ecto.Changeset.t()}
  def upsert_polity(attrs) do
    %Polity{}
    |> Polity.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        from(p in Polity,
          update: [
            set: [
              from_year: fragment("COALESCE(EXCLUDED.from_year, ?)", p.from_year),
              to_year: fragment("COALESCE(EXCLUDED.to_year, ?)", p.to_year),
              updated_at: fragment("EXCLUDED.updated_at")
            ]
          ]
        ),
      conflict_target: [:name, :source],
      returning: true
    )
  end

  @doc """
  Replaces every `atlas.borders` row of `source` with `rows` (issue #023):
  purges the source's existing rows, then runs the geometry pipeline
  (`Amanogawa.Atlas.BorderQueries.insert_batch/3`, ST_MakeValid,
  ST_CollectionExtract, ST_Multi, ST_SimplifyPreserveTopology) and inserts
  every surviving row, batching `rows` (any `Enumerable`, typically a lazy
  `Stream` from the ingestion parser so a 300MB source file never has to be
  held in memory at once) into groups of #{@border_batch_size}.

  Runs inside a single database transaction spanning the whole call (purge
  and every insert batch): a crash partway through leaves the previous
  state of `source` untouched rather than a half-replaced one, and
  `:infinity` timeout since a full Cliopatria import can legitimately take
  longer than Ecto's 15 second default query timeout.

  Idempotent: replaying the same `rows` for the same `source` produces the
  same final row count, regardless of what was there before under that
  source. Borders of other sources are never touched (the purge is scoped
  to `source`), and polities of `source` left without a single border row
  by the replacement (an entity the new file no longer carries) are purged
  in the same transaction, so `atlas.polities` never accumulates orphans
  across re-imports.

  ## Anti-wipe guard

  A purge that removed rows followed by zero insertions is, in every
  legitimate scenario, a wrong file or a wholly corrupted one (100% of
  features rejected upstream), not a real "this source is now empty"
  import: the transaction is rolled back
  (`{:error, {:would_wipe_source, source, purged}}`) and the previous
  data survives. Pass `force: true` (exposed as `--force` by both import
  mix tasks) to deliberately empty a source instead.

  Returns `{:ok, stats}` with `:purged` (rows deleted before reinsertion),
  `:purged_polities` (orphaned polities removed at the end), `:total`
  (rows read from `rows`), `:repaired` (rows whose raw geometry was
  invalid before `ST_MakeValid`), `:inserted` and `:rejected_empty`
  (still empty after repair, logged by the caller, never raised).

  `rows`: see `Amanogawa.Atlas.BorderQueries.raw_row/0` for the expected
  shape (`:polity_id`, `:geometry` as a raw GeoJSON geometry map,
  `:from_year`, `:to_year`, `:source`, `:precision`).
  """
  @spec replace_borders(String.t(), Enumerable.t(), keyword()) ::
          {:ok, map()} | {:error, {:would_wipe_source, String.t(), pos_integer()}}
  def replace_borders(source, rows, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    Repo.transaction(
      fn ->
        purged = BorderQueries.purge_source(source)

        stats =
          rows
          |> Stream.chunk_every(@border_batch_size)
          |> Enum.reduce(empty_border_stats(), fn batch, acc ->
            batch |> BorderQueries.insert_batch() |> merge_border_stats(acc)
          end)

        if purged > 0 and stats.inserted == 0 and not force do
          Repo.rollback({:would_wipe_source, source, purged})
        end

        purged_polities = BorderQueries.purge_orphan_polities(source)

        stats
        |> Map.put(:purged, purged)
        |> Map.put(:purged_polities, purged_polities)
      end,
      timeout: :infinity
    )
  end

  @doc "Counts borders. Used by tests and import summaries."
  @spec count_borders() :: non_neg_integer()
  def count_borders, do: Repo.aggregate(Border, :count)

  @doc """
  Lists the polygons active at `year` as a GeoJSON `FeatureCollection`
  (issue #025): `year` is already clamped and validated by
  `AmanogawaWeb.Params.BorderQuery.parse/1` before it reaches here.

  Read-only and side-effect free. The query itself, including the
  `ST_AsGeoJSON` serialization and the `area_km2` computation, is
  centralized in `Amanogawa.Atlas.BorderQueries.list_active_borders/1`;
  this function only shapes the result into GeoJSON and attaches each
  feature's stable color (`Amanogawa.Atlas.PolityColor.for_name/1`), the
  boundary where PostGIS geometry becomes wire format
  (`.claude/rules/geo-temporal.md`).

  Every feature carries `name`, `source`, `precision`, `color` (hashed
  from `name`, stable across years so the same entity keeps the same hue
  as the caller changes `year`) and `area_km2` (used by the map hook to
  gate labels to large entities only, issue #025).
  """
  @spec list_borders_geojson(integer()) :: map()
  def list_borders_geojson(year) do
    features =
      year
      |> BorderQueries.list_active_borders()
      |> Enum.map(&border_row_to_feature/1)

    %{"type" => "FeatureCollection", "features" => features}
  end

  @doc """
  The timestamp of the most recent borders import, or `nil` when
  `atlas.borders` is empty. Delegates to
  `Amanogawa.Atlas.BorderQueries.last_import_at/0`, exposed here so the
  web layer (the borders endpoint's ETag,
  `AmanogawaWeb.Controllers.Api.BorderController`) only ever depends on
  `Amanogawa.Atlas`'s public API.
  """
  @spec last_border_import_at() :: DateTime.t() | nil
  def last_border_import_at, do: BorderQueries.last_import_at()

  @doc """
  Counts pairs of borders of `source` sharing the same polity where one
  row's `to_year` equals another's `from_year` (issue #023's "années
  charnières" check): under this project's inclusive `[from_year,
  to_year]` convention, such a pair double-covers the boundary year.
  Delegates to `Amanogawa.Atlas.BorderQueries.
  count_boundary_year_overlaps/1`; used by the Cliopatria import task to
  warn (never fail) when the source's interval convention needs
  normalizing.
  """
  @spec count_boundary_year_overlaps(String.t()) :: non_neg_integer()
  defdelegate count_boundary_year_overlaps(source), to: BorderQueries

  @doc "Counts polities. Used by tests and import summaries."
  @spec count_polities() :: non_neg_integer()
  def count_polities, do: Repo.aggregate(Polity, :count)

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

  `article_url` is validated (`Amanogawa.WikimediaUrl.valid?/1`, defense in
  depth: `Amanogawa.Ingestion.WikipediaClient.Rest` always populates it
  from the response's own `content_urls.desktop.page`, itself already a
  Wikimedia URL by construction, but this is the write boundary, the one
  place a malformed or hostile value would otherwise reach storage
  regardless of how it got here). An invalid `article_url` fails the same
  way any other invalid changeset field does: `{:error, changeset}`,
  nothing is written.
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
    |> validate_article_url(article_url)
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

  defp validate_article_url(changeset, article_url) do
    if WikimediaUrl.valid?(article_url) do
      changeset
    else
      add_error(changeset, :extract_attribution, "article_url must be a valid Wikimedia URL")
    end
  end

  # Builds the dense bucket list `event_histogram/1` returns, from the
  # exact integer edges `EventQueries.bucket_edges/1` defines (the same
  # edges the SQL aggregation assigns against). `counts` (from
  # `EventQueries.histogram_counts/1`) is sparse and 1-indexed
  # (PostgreSQL's `width_bucket` convention); a bucket absent from it is a
  # genuine zero, not a gap, so every bucket index in `1..buckets` is
  # looked up with a `0` default.
  defp bucket_list(opts, counts) do
    opts
    |> EventQueries.bucket_edges()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index(1)
    |> Enum.map(fn {[edge_from, edge_to], index} ->
      %{"from" => edge_from, "to" => edge_to, "count" => Map.get(counts, index, 0)}
    end)
  end

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

  defp event_row_to_feature(row) do
    %{
      "type" => "Feature",
      "geometry" => Geo.JSON.encode!(row.geom),
      "properties" => %{
        "qid" => row.qid,
        "label" => row.label,
        "year" => row.year,
        "precision" => row.precision,
        "importance" => row.importance
      }
    }
  end

  # `row.geometry` is already GeoJSON text (`ST_AsGeoJSON`,
  # `BorderQueries.list_active_borders/1`): decoded here into the map
  # `Jason.encode!/1` needs at the controller's `json/2` call, never
  # re-serialized from a `Geo` struct the way `event_row_to_feature/1`
  # above does (borders never build one, ADR 0007's "GeoJSON at the web
  # edge" is already satisfied one layer down, in SQL).
  defp border_row_to_feature(row) do
    %{
      "type" => "Feature",
      "geometry" => Jason.decode!(row.geometry),
      "properties" => %{
        "name" => row.name,
        "source" => row.source,
        "precision" => row.precision,
        "color" => PolityColor.for_name(row.name),
        "area_km2" => Float.round(row.area_km2, 1)
      }
    }
  end

  defp event_summary(event) do
    {extract, extract_language} = extract_with_language(event)

    %{
      qid: event.qid,
      label: event.label_fr || event.label_en,
      extract: extract,
      thumbnail_url: event.thumbnail_url,
      wiki_url: event.wiki_url_fr || event.wiki_url_en,
      extract_language: extract_language,
      fetched_at: event.extract_fetched_at
    }
  end

  defp extract_with_language(%Event{extract_fr: extract_fr}) when is_binary(extract_fr),
    do: {extract_fr, "fr"}

  defp extract_with_language(%Event{extract_en: extract_en}) when is_binary(extract_en),
    do: {extract_en, "en"}

  defp extract_with_language(%Event{}), do: {nil, nil}

  # No geometry on the selected event itself: nothing to anchor a line to,
  # regardless of how many relations it has.
  defp event_links_feature_collection(%Event{geom: nil}) do
    %{"type" => "FeatureCollection", "features" => []}
  end

  defp event_links_feature_collection(event) do
    features =
      event.id
      |> EventQueries.list_links()
      |> Enum.map(&link_row_to_feature(event, &1))

    %{"type" => "FeatureCollection", "features" => features}
  end

  # Coordinates run from the selected event to the related one, whichever
  # side of the relation it sits on (`direction` carries which). A
  # degenerate LineString (both endpoints at the same point) is kept as-is:
  # rare, harmless to render (MapLibre draws a zero-length line, invisible
  # but not an error), and excluding it would need a floating-point
  # coordinate equality check that is not worth its complexity for a case
  # with no observed real-world occurrence.
  defp link_row_to_feature(event, row) do
    line = %Geo.LineString{
      coordinates: [event.geom.coordinates, row.target_geom.coordinates],
      srid: 4326
    }

    %{
      "type" => "Feature",
      "geometry" => Geo.JSON.encode!(line),
      "properties" => %{
        "link_type" => Atom.to_string(row.type),
        "direction" => Atom.to_string(row.direction),
        "target_qid" => row.target_qid,
        "target_label" => row.target_label,
        "target_year" => row.target_year
      }
    }
  end

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)

  defp empty_border_stats, do: %{total: 0, repaired: 0, inserted: 0, rejected_empty: 0}

  defp merge_border_stats(batch_stats, acc) do
    Map.merge(acc, batch_stats, fn _key, a, b -> a + b end)
  end
end
