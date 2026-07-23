defmodule Amanogawa.HistoricalDate.Wikidata do
  @moduledoc """
  Pure normalization of Wikidata time values into `Amanogawa.HistoricalDate`.

  No transport concern lives here: the ingestion adapter (SPARQL client) is
  responsible for fetching the raw bindings; this module only turns them into
  domain values. Two channels are supported because Wikidata itself is
  inconsistent between them:

    * `from_rdf/1` for SPARQL query results, where the RDF/XSD 1.1 encoding
      is already astronomical (458 BCE is `-0457`).
    * `from_json/1` for the weekly JSON dumps, where 1 BCE is noted `-0001`:
      negative years are shifted by `+1` to reach the astronomical
      convention used everywhere else in the project (1 BCE = year `0`).

  Both channels store a fake "January 1" whenever the precision is coarser
  than a day; `Amanogawa.HistoricalDate.changeset/2` truncates month/day
  according to precision, so that truncation is applied uniformly here too
  rather than duplicated.

  Time strings are never parsed with `Date`/`DateTime`/`NaiveDateTime`:
  Elixir's calendar types cannot represent the range this project needs
  (down to -123000 and beyond), so years, months and days are extracted by
  hand from the ISO-8601-like string Wikidata emits.

  ## Examples

      iex> Amanogawa.HistoricalDate.Wikidata.from_rdf(%{
      ...>   time: "-0489-09-12T00:00:00Z",
      ...>   precision: 11,
      ...>   calendar: "http://www.wikidata.org/entity/Q1985786"
      ...> })
      {:ok, %Amanogawa.HistoricalDate{year: -489, month: 9, day: 12, precision: 11, calendar: :julian}}

      iex> Amanogawa.HistoricalDate.Wikidata.from_json(%{
      ...>   time: "-0490-09-12T00:00:00Z",
      ...>   precision: 11,
      ...>   calendar: "http://www.wikidata.org/entity/Q1985786"
      ...> })
      {:ok, %Amanogawa.HistoricalDate{year: -489, month: 9, day: 12, precision: 11, calendar: :julian}}

  """

  alias Amanogawa.HistoricalDate

  @gregorian_qid "Q1985727"
  @julian_qid "Q1985786"

  @time_regex ~r/\A([+-]?)(\d+)-(\d{2})-(\d{2})T\d{2}:\d{2}:\d{2}Z\z/

  @type rdf_binding :: %{
          required(:time) => String.t(),
          required(:precision) => HistoricalDate.precision(),
          required(:calendar) => String.t()
        }
  @type error :: {:invalid_time, term()} | {:invalid_calendar, term()}

  @doc """
  Normalizes a SPARQL (RDF) time binding. The year is kept as-is: RDF/XSD 1.1
  is already in astronomical convention.
  """
  @spec from_rdf(rdf_binding()) ::
          {:ok, HistoricalDate.t()} | {:error, error() | Ecto.Changeset.t()}
  def from_rdf(%{time: time, precision: precision, calendar: calendar}) do
    build(time, precision, calendar, & &1)
  end

  @doc """
  Normalizes a JSON dump time binding. Negative years are shifted by `+1`:
  the JSON format notes 1 BCE as `-0001`, which is year `0` astronomically.
  """
  @spec from_json(rdf_binding()) ::
          {:ok, HistoricalDate.t()} | {:error, error() | Ecto.Changeset.t()}
  def from_json(%{time: time, precision: precision, calendar: calendar}) do
    build(time, precision, calendar, &shift_json_year/1)
  end

  defp build(time, precision, calendar, year_fun) do
    with {:ok, {year, month, day}} <- parse_time(time),
         {:ok, calendar_atom} <- parse_calendar(calendar) do
      HistoricalDate.new(%{
        year: year_fun.(year),
        month: month,
        day: day,
        precision: precision,
        calendar: calendar_atom
      })
    end
  end

  defp shift_json_year(year) when year <= -1, do: year + 1
  defp shift_json_year(year), do: year

  defp parse_time(time) when is_binary(time) do
    case Regex.run(@time_regex, time) do
      [_, sign, year_digits, month_digits, day_digits] ->
        year = apply_sign(sign, String.to_integer(year_digits))
        {:ok, {year, String.to_integer(month_digits), String.to_integer(day_digits)}}

      nil ->
        {:error, {:invalid_time, time}}
    end
  end

  defp parse_time(other), do: {:error, {:invalid_time, other}}

  defp apply_sign("-", value), do: -value
  defp apply_sign(_sign, value), do: value

  defp parse_calendar(url) when is_binary(url) do
    case Regex.run(~r/(Q\d+)\z/, url) do
      [_, @gregorian_qid] -> {:ok, :gregorian}
      [_, @julian_qid] -> {:ok, :julian}
      _ -> {:error, {:invalid_calendar, url}}
    end
  end

  defp parse_calendar(other), do: {:error, {:invalid_calendar, other}}
end
