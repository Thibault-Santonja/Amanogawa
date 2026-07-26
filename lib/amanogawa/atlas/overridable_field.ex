defmodule Amanogawa.Atlas.OverridableField do
  @moduledoc """
  Internal to the Atlas context (`.claude/rules/architecture.md`): called
  only from `Amanogawa.Atlas` itself (`apply_field_override/3`,
  `release_field_override/3`, and the conditional `ON CONFLICT` clause
  `upsert_events/1` builds, issue #035), never from `Amanogawa.
  Contributions` or the web layer directly.

  The single definition of which `atlas.events` columns a
  contribution-overridable business field owns (F08 overview's "le
  mapping champ métier -> colonnes vit à UN endroit"), and how to turn a
  jsonb override payload, as `Amanogawa.Contributions.Override` stores it
  (plain maps with string keys, see its moduledoc), into the column
  values to write.

  The five business field names this module knows (`:label_fr`,
  `:label_en`, `:begin_date`, `:end_date`, `:position`) are the closed set
  `Amanogawa.Contributions.Override` also validates its own `field`
  column against: kept in sync by hand, not by a shared reference, since
  `Amanogawa.Contributions` never calls into this internal module
  directly (`Amanogawa.Atlas.apply_field_override/3` and
  `release_field_override/3` are the only door, per the architecture
  rule).
  """

  alias Amanogawa.Atlas.Event
  alias Amanogawa.HistoricalDate

  @type field :: :label_fr | :label_en | :begin_date | :end_date | :position

  @doc """
  Converts a jsonb override payload for `field` into the `atlas.events`
  column values an ACCEPTED override writes
  (`Amanogawa.Atlas.apply_field_override/3`): `:position` always forces
  `location_source` to `:contribution`, since applying an override is by
  construction a human correction, whatever the payload itself carries
  (a proposal never includes a provenance, only coordinates).
  """
  @spec to_applied_attrs(field(), map() | nil) :: map()
  def to_applied_attrs(:label_fr, %{"value" => value}), do: %{label_fr: value}
  def to_applied_attrs(:label_en, %{"value" => value}), do: %{label_en: value}
  def to_applied_attrs(:begin_date, payload), do: date_attrs(payload, :begin)
  def to_applied_attrs(:end_date, payload), do: date_attrs(payload, :end)

  def to_applied_attrs(:position, payload) do
    payload |> position_geom() |> Map.put(:location_source, :contribution)
  end

  @doc """
  Converts a jsonb value payload for `field` into the `atlas.events`
  column values a RELEASE restores (`Amanogawa.Atlas.
  release_field_override/3`): unlike `to_applied_attrs/2`, `:position`
  takes `location_source` from the payload itself (the provenance
  Wikidata actually carries for this value), never forcing
  `:contribution`.
  """
  @spec to_released_attrs(field(), map() | nil) :: map()
  def to_released_attrs(:label_fr, %{"value" => value}), do: %{label_fr: value}
  def to_released_attrs(:label_en, %{"value" => value}), do: %{label_en: value}
  def to_released_attrs(:begin_date, payload), do: date_attrs(payload, :begin)
  def to_released_attrs(:end_date, payload), do: date_attrs(payload, :end)

  def to_released_attrs(:position, %{"location_source" => source} = payload) do
    payload |> position_geom() |> Map.put(:location_source, location_source_atom(source))
  end

  # `nil` means "Wikidata carries no value at all for this field"
  # (`Amanogawa.Contributions`' own absent-value convention, e.g. an
  # event that never had a geometry when its position override was
  # accepted): releasing restores that absence instead of crashing on a
  # payload shape no clause matches.
  def to_released_attrs(:label_fr, nil), do: %{label_fr: nil}
  def to_released_attrs(:label_en, nil), do: %{label_en: nil}
  def to_released_attrs(:position, nil), do: %{geom: nil, location_source: nil}

  # Total conversion of a stored provenance string (defense in depth: the
  # payload round-tripped through jsonb, so its content is data, never a
  # value `String.to_existing_atom/1` may be trusted with).
  defp location_source_atom("direct"), do: :direct
  defp location_source_atom("place"), do: :place
  defp location_source_atom("country"), do: :country
  defp location_source_atom("contribution"), do: :contribution
  defp location_source_atom(_other), do: nil

  # `nil` means "no date at all" (`Amanogawa.Contributions`' own
  # "absent value" convention, its moduledoc): the only business field
  # this legitimately happens for is `:end_date` (most events are
  # punctual, and removing an erroneous end date is itself a valid
  # correction, issue #034's edge case), never `:begin_date` (required at
  # the `Amanogawa.Atlas.Event` level, so a `nil` payload never reaches
  # here for it).
  defp date_attrs(nil, group), do: Event.flatten_date(nil, group)

  defp date_attrs(payload, group) do
    %{
      "year" => year,
      "month" => month,
      "day" => day,
      "precision" => precision,
      "calendar" => calendar
    } = payload

    date =
      HistoricalDate.new!(%{
        year: year,
        month: month,
        day: day,
        precision: precision,
        calendar: calendar_atom(calendar)
      })

    Event.flatten_date(date, group)
  end

  # Total conversion (security review, calendar finding): the payload is
  # stored jsonb, so a forged/legacy calendar string must degrade to
  # `nil` (calendar unknown) instead of feeding
  # `String.to_existing_atom/1` a crash.
  defp calendar_atom("gregorian"), do: :gregorian
  defp calendar_atom("julian"), do: :julian
  defp calendar_atom(_other), do: nil

  # `/ 1` promotes a jsonb integer (a whole-number coordinate, e.g. `48`)
  # to a float: `Geo.Point` coordinates are always floats regardless of
  # whether the jsonb payload happened to round-trip a value with no
  # fractional part as a JSON integer.
  defp position_geom(%{"lon" => lon, "lat" => lat}) do
    %{geom: %Geo.Point{coordinates: {lon / 1, lat / 1}, srid: 4326}}
  end
end
