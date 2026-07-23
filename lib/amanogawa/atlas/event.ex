defmodule Amanogawa.Atlas.Event do
  @moduledoc """
  A historical event, the read model row served to the UI.

  Identified by its Wikidata QID (unique, upsert key); the internal `id` is
  a UUID v7 so ids are naturally time-ordered on insert. Begin/end dates are
  stored as flat `begin_*`/`end_*` columns (see ADR 0006): `begin_date/1` and
  `end_date/1` rebuild an `Amanogawa.HistoricalDate` from them, and
  `flatten_date/2` does the inverse, used both by ingestion (to build
  `insert_all` rows) and by tests (to build fixtures).

  Internal to the Atlas context: only `Amanogawa.Atlas` is called from other
  contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Amanogawa.HistoricalDate
  alias Amanogawa.WikimediaUrl

  @type t :: %__MODULE__{}

  @schema_prefix "atlas"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  schema "events" do
    field :qid, :string

    field :label_fr, :string
    field :label_en, :string
    field :description_fr, :string
    field :description_en, :string

    field :extract_fr, :string
    field :extract_en, :string
    field :wiki_url_fr, :string
    field :wiki_url_en, :string

    field :kind, :string

    field :begin_year, :integer
    field :begin_month, :integer
    field :begin_day, :integer
    field :begin_precision, :integer
    field :begin_calendar, Ecto.Enum, values: [:gregorian, :julian]

    field :end_year, :integer
    field :end_month, :integer
    field :end_day, :integer
    field :end_precision, :integer
    field :end_calendar, Ecto.Enum, values: [:gregorian, :julian]

    field :geom, Geo.PostGIS.Geometry
    field :location_source, Ecto.Enum, values: [:direct, :place, :country]
    field :sitelink_count, :integer, default: 0

    # Wikipedia enrichment (#012): `extract_fetched_at` is the cache
    # freshness marker (set on every attempt, successful or not, see
    # `summary_changeset/2`), `extract_attribution` the CC BY-SA 4.0
    # attribution stored alongside the extract it covers.
    field :extract_fetched_at, :utc_datetime
    field :thumbnail_url, :string
    field :extract_attribution, :map

    timestamps(type: :utc_datetime)
  end

  @castable_fields [
    :qid,
    :label_fr,
    :label_en,
    :description_fr,
    :description_en,
    :extract_fr,
    :extract_en,
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
    :extract_fetched_at,
    :thumbnail_url,
    :extract_attribution
  ]

  # Cast by both `changeset/2` (fixtures, general-purpose writes) and
  # `summary_changeset/2` (the enrichment write path,
  # `Amanogawa.Atlas.put_event_summary/2` and `mark_summary_attempt/1`).
  @summary_fields [
    :extract_fr,
    :extract_en,
    :thumbnail_url,
    :extract_attribution,
    :extract_fetched_at
  ]

  @qid_regex ~r/\AQ\d+\z/

  @doc """
  Builds and validates a changeset.

  The QID must match `Q\\d+`; `begin_*`/`end_*` coherence (precision-driven
  month/day truncation) is enforced by delegating to
  `Amanogawa.HistoricalDate.changeset/2` for each of the two date groups,
  so the invariant is defined in exactly one place. `end_*` is left alone
  when `end_year` is nil (most events are punctual). The geometry, when
  present, must be a `Geo.Point` with SRID 4326.

  `wiki_url_fr`/`wiki_url_en` and `thumbnail_url`, when present, are
  validated against `Amanogawa.WikimediaUrl` (defense in depth,
  security review: ingestion already rejects a hostile URL before it
  reaches storage, `Amanogawa.Ingestion.Wikidata.EventDecoder` and
  `Amanogawa.Ingestion.WikipediaClient.Summary`, but this changeset is
  also the one general-purpose write path shared with test fixtures and
  any future direct write, so the invariant is enforced here too rather
  than trusted to hold by construction everywhere it is called).
  `thumbnail_url` is held to the stricter `valid_thumbnail?/1` (only the
  Wikimedia upload host, matching the CSP's `img-src`), the wiki URLs to
  the more permissive `valid?/1` (any `*.wikipedia.org` host).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, @castable_fields)
    |> validate_required([:qid, :begin_year])
    |> validate_format(:qid, @qid_regex, message: "must be a Wikidata QID, e.g. Q12345")
    |> unique_constraint(:qid)
    |> apply_historical_date_invariants(:begin)
    |> apply_historical_date_invariants(:end)
    |> validate_geom_srid()
    |> validate_wikimedia_url(:wiki_url_fr, &WikimediaUrl.valid?/1)
    |> validate_wikimedia_url(:wiki_url_en, &WikimediaUrl.valid?/1)
    |> validate_wikimedia_url(:thumbnail_url, &WikimediaUrl.valid_thumbnail?/1)
    |> validate_attribution()
  end

  @doc """
  Builds the changeset for the Wikipedia enrichment write path
  (`Amanogawa.Atlas.put_event_summary/2`, `mark_summary_attempt/1`): casts
  only the enrichment columns (`#{inspect(@summary_fields)}`), leaving
  every Wikidata-sourced column untouched. `attrs` carries whichever subset
  applies: a successful fetch sets `extract_fr` or `extract_en`,
  `thumbnail_url`, `extract_attribution` and `extract_fetched_at`; a
  `:not_found` attempt (`mark_summary_attempt/1`) sets only
  `extract_fetched_at`, so the cache still treats the article as recently
  checked without fabricating an extract.

  `thumbnail_url`, when present, is validated the same way as in
  `changeset/2` above (`Amanogawa.WikimediaUrl.valid_thumbnail?/1`).
  """
  @spec summary_changeset(t(), map()) :: Ecto.Changeset.t()
  def summary_changeset(event, attrs) do
    event
    |> cast(attrs, @summary_fields)
    |> validate_wikimedia_url(:thumbnail_url, &WikimediaUrl.valid_thumbnail?/1)
    |> validate_attribution()
  end

  @doc """
  Rebuilds the begin `HistoricalDate` from the flat `begin_*` columns.
  """
  @spec begin_date(t()) :: HistoricalDate.t()
  def begin_date(%__MODULE__{} = event) do
    HistoricalDate.new!(%{
      year: event.begin_year,
      month: event.begin_month,
      day: event.begin_day,
      precision: event.begin_precision,
      calendar: event.begin_calendar
    })
  end

  @doc """
  Rebuilds the end `HistoricalDate` from the flat `end_*` columns, or
  returns `nil` when the event has no recorded end (most events).
  """
  @spec end_date(t()) :: HistoricalDate.t() | nil
  def end_date(%__MODULE__{end_year: nil}), do: nil

  def end_date(%__MODULE__{} = event) do
    HistoricalDate.new!(%{
      year: event.end_year,
      month: event.end_month,
      day: event.end_day,
      precision: event.end_precision,
      calendar: event.end_calendar
    })
  end

  @doc """
  Flattens a `HistoricalDate` (or `nil`) into `begin_*`/`end_*` attributes,
  the inverse of `begin_date/1` and `end_date/1`. Used by the ingestion
  normalizer to build rows for `Amanogawa.Atlas.upsert_events/1` and by
  tests to build fixtures.
  """
  @spec flatten_date(HistoricalDate.t() | nil, :begin | :end) :: map()
  def flatten_date(nil, :begin) do
    %{
      begin_year: nil,
      begin_month: nil,
      begin_day: nil,
      begin_precision: nil,
      begin_calendar: nil
    }
  end

  def flatten_date(nil, :end) do
    %{end_year: nil, end_month: nil, end_day: nil, end_precision: nil, end_calendar: nil}
  end

  def flatten_date(%HistoricalDate{} = date, :begin) do
    %{
      begin_year: date.year,
      begin_month: date.month,
      begin_day: date.day,
      begin_precision: date.precision,
      begin_calendar: date.calendar
    }
  end

  def flatten_date(%HistoricalDate{} = date, :end) do
    %{
      end_year: date.year,
      end_month: date.month,
      end_day: date.day,
      end_precision: date.precision,
      end_calendar: date.calendar
    }
  end

  # Field atoms are always one of the small, closed set below (never built
  # from external input): kept as explicit pattern matches, rather than
  # `:"#{prefix}_#{field}"` interpolation, so no dynamic atom is ever
  # constructed from a changeset value.
  defp apply_historical_date_invariants(changeset, :begin) do
    apply_date_group(
      changeset,
      :begin_year,
      :begin_month,
      :begin_day,
      :begin_precision,
      :begin_calendar,
      &begin_error_field/1
    )
  end

  defp apply_historical_date_invariants(changeset, :end) do
    apply_date_group(
      changeset,
      :end_year,
      :end_month,
      :end_day,
      :end_precision,
      :end_calendar,
      &end_error_field/1
    )
  end

  defp apply_date_group(
         changeset,
         year_field,
         month_field,
         day_field,
         precision_field,
         calendar_field,
         error_field
       ) do
    case get_field(changeset, year_field) do
      nil ->
        changeset

      year ->
        date_attrs = %{
          year: year,
          month: get_field(changeset, month_field),
          day: get_field(changeset, day_field),
          precision: get_field(changeset, precision_field),
          calendar: get_field(changeset, calendar_field) || :gregorian
        }

        date_changeset = HistoricalDate.changeset(%HistoricalDate{}, date_attrs)

        changeset
        |> put_change(month_field, get_field(date_changeset, :month))
        |> put_change(day_field, get_field(date_changeset, :day))
        |> put_change(calendar_field, get_field(date_changeset, :calendar))
        |> merge_errors(date_changeset, error_field)
    end
  end

  defp merge_errors(changeset, date_changeset, error_field) do
    Enum.reduce(date_changeset.errors, changeset, fn {field, {message, opts}}, acc ->
      add_error(acc, error_field.(field), message, opts)
    end)
  end

  # Only :year, :precision, :month and :day are mapped (:year can fail its
  # bounds validation even when present); :calendar cannot fail validation
  # here (Event's own top-level cast/3 already rejects an invalid enum
  # value before this code ever runs). A HistoricalDate error on any other
  # field would mean the shared invariant grew a new case without this
  # module being updated to match: let it crash rather than silently drop
  # it.
  defp begin_error_field(:year), do: :begin_year
  defp begin_error_field(:month), do: :begin_month
  defp begin_error_field(:day), do: :begin_day
  defp begin_error_field(:precision), do: :begin_precision

  defp end_error_field(:year), do: :end_year
  defp end_error_field(:month), do: :end_month
  defp end_error_field(:day), do: :end_day
  defp end_error_field(:precision), do: :end_precision

  defp validate_geom_srid(changeset) do
    case get_field(changeset, :geom) do
      nil -> changeset
      %Geo.Point{srid: 4326} -> changeset
      %Geo.Point{} -> add_error(changeset, :geom, "must have SRID 4326")
      _ -> add_error(changeset, :geom, "must be a Point geometry")
    end
  end

  # A `nil` field (most events lack one or more of these URLs) is never an
  # error: only a *present but invalid* value is rejected. `validator` is
  # `WikimediaUrl.valid?/1` or the stricter `valid_thumbnail?/1`, chosen
  # per field by the caller.
  defp validate_wikimedia_url(changeset, field, validator) do
    case get_field(changeset, field) do
      nil ->
        changeset

      url ->
        if validator.(url) do
          changeset
        else
          add_error(changeset, field, "must be a valid Wikimedia URL")
        end
    end
  end

  # `extract_attribution` must be able to render "Source: Wikipedia, CC
  # BY-SA 4.0" with a link on its own: the license alone, without the
  # article URL, is not sufficient attribution (`.claude/rules/ethics.md`).
  defp validate_attribution(changeset) do
    case get_field(changeset, :extract_attribution) do
      nil ->
        changeset

      %{"article_url" => url, "license" => license}
      when is_binary(url) and is_binary(license) ->
        changeset

      _invalid ->
        add_error(changeset, :extract_attribution, "must include article_url and license")
    end
  end
end
