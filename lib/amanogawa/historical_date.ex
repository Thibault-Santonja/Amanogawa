defmodule Amanogawa.HistoricalDate do
  @moduledoc """
  Value object representing a historical date from prehistory to today.

  PostgreSQL's `date` type cannot represent years before -4713 and language
  date types generally assume the modern Gregorian calendar, so every
  historical date in the project is carried as a signed astronomical year
  (1 BCE is year `0`, 490 BCE is year `-489`) together with an explicit
  precision on the Wikidata 0-11 scale and an optional month/day.

  This module is a shared kernel: it lives above the bounded contexts and is
  used by Atlas (storage, `Amanogawa.Atlas.Event`), Ingestion (normalization,
  `Amanogawa.HistoricalDate.Wikidata`) and the web layer (display,
  `Amanogawa.HistoricalDate.Formatter`), without depending on any of them.

  `month` and `day` only carry meaning when the precision says so: if
  `precision <= 9` (year or coarser), both are forced to `nil`; if
  `precision == 10` (month), only `day` is forced to `nil`. This truncation
  happens in `changeset/2` itself, so it applies uniformly however a date is
  built.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type calendar :: :gregorian | :julian
  @type precision :: 0..11
  @type t :: %__MODULE__{
          year: integer(),
          month: 1..12 | nil,
          day: 1..31 | nil,
          precision: precision(),
          calendar: calendar()
        }

  @primary_key false
  embedded_schema do
    field :year, :integer
    field :month, :integer
    field :day, :integer
    field :precision, :integer
    field :calendar, Ecto.Enum, values: [:gregorian, :julian], default: :gregorian
  end

  @doc """
  Builds and validates a changeset from a `%HistoricalDate{}` (or the empty
  struct) and a map of attributes.

  Invariants enforced:

    * `precision` is required and must fall in `0..11`.
    * if `precision <= 9`, `month` and `day` are truncated to `nil`.
    * if `precision == 10`, `day` is truncated to `nil`.
    * `month` must be in `1..12` and `day` in `1..31` when present.
    * `day` present without `month` is rejected.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(historical_date, attrs) do
    historical_date
    |> cast(attrs, [:year, :month, :day, :precision, :calendar])
    |> validate_required([:year, :precision])
    |> validate_inclusion(:precision, 0..11)
    |> truncate_for_precision()
    |> validate_month_range()
    |> validate_day_range()
    |> validate_day_requires_month()
  end

  @doc """
  Validating constructor. Returns `{:ok, date}` or `{:error, changeset}`.
  """
  @spec new(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def new(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @doc """
  Same as `new/1` but raises `Ecto.InvalidChangesetError` on invalid input.
  """
  @spec new!(map()) :: t()
  def new!(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action!(:insert)
  end

  @doc """
  Returns a sortable key implementing the project-wide chronological order
  `(year, month NULLS FIRST, day NULLS FIRST)`.

  Unlike `compare/2`, this key is a genuine total order usable with
  `Enum.sort_by/2`: a date with an unknown month always sorts before a date
  of the same year with a known month, regardless of precision.
  """
  @spec sort_key(t()) :: {integer(), {0, 0} | {1, integer()}, {0, 0} | {1, integer()}}
  def sort_key(%__MODULE__{} = date) do
    {date.year, nullable_key(date.month), nullable_key(date.day)}
  end

  defp nullable_key(nil), do: {0, 0}
  defp nullable_key(value), do: {1, value}

  @doc """
  Compares two historical dates chronologically.

  Years are always compared. Within the same year, the comparison is only
  significant (month, then day, NULLS FIRST) when **both** dates have
  `precision >= 10`; otherwise the dates are considered equal at the year
  level, since neither the data nor the historical record supports a finer
  distinction (a date known only to the year cannot be said to come before
  or after a day-precise date of the same year).

  This makes `compare/2` reflexive and antisymmetric, but note it is not a
  strict total order: because dates of different precisions collapse to
  year-level equality, the relation is not transitive across differing
  precisions (a year-only date can be "equal" to two day-precise dates of
  the same year that are themselves ordered). `sort_key/1` is the function
  to reach for when a genuine total order is required (list sorting).
  """
  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(%__MODULE__{} = date1, %__MODULE__{} = date2) do
    cond do
      date1.year < date2.year -> :lt
      date1.year > date2.year -> :gt
      date1.precision < 10 or date2.precision < 10 -> :eq
      true -> compare_month_day(date1, date2)
    end
  end

  defp compare_month_day(date1, date2) do
    key1 = {nullable_key(date1.month), nullable_key(date1.day)}
    key2 = {nullable_key(date2.month), nullable_key(date2.day)}

    cond do
      key1 == key2 -> :eq
      key1 < key2 -> :lt
      true -> :gt
    end
  end

  defp truncate_for_precision(changeset) do
    case get_field(changeset, :precision) do
      precision when is_integer(precision) and precision <= 9 ->
        changeset |> put_change(:month, nil) |> put_change(:day, nil)

      10 ->
        put_change(changeset, :day, nil)

      _ ->
        changeset
    end
  end

  defp validate_month_range(changeset) do
    case get_field(changeset, :month) do
      nil -> changeset
      month when month in 1..12 -> changeset
      _ -> add_error(changeset, :month, "must be between 1 and 12")
    end
  end

  defp validate_day_range(changeset) do
    case get_field(changeset, :day) do
      nil -> changeset
      day when day in 1..31 -> changeset
      _ -> add_error(changeset, :day, "must be between 1 and 31")
    end
  end

  defp validate_day_requires_month(changeset) do
    case {get_field(changeset, :day), get_field(changeset, :month)} do
      {day, nil} when not is_nil(day) ->
        add_error(changeset, :month, "is required when day is present")

      _ ->
        changeset
    end
  end
end
