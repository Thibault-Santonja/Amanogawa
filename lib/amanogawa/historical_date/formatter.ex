defmodule Amanogawa.HistoricalDate.Formatter do
  @moduledoc """
  Renders an `Amanogawa.HistoricalDate` as human-readable text, strictly
  respecting its precision: a date known only to the century is rendered as
  "VIIIe siecle av. J.-C.", never as an invented day such as
  "1er janvier -0750".

  Full Gettext internationalization is a web-layer concern for later; this
  module supports `:fr` (default) and `:en` directly so the rest of the
  domain (and its tests) can rely on honest formatting today. French output
  uses correctly accented text (é, è, à, ...).

  Astronomical years `<= 0` are converted for display as BCE dates:
  `1 - year` BCE (year `0` is "1 av. J.-C.", year `-489` is "490 av. J.-C.").

  ## Examples

      iex> Amanogawa.HistoricalDate.Formatter.format(Amanogawa.HistoricalDate.new!(%{year: -700, precision: 7}))
      "VIIIe siècle av. J.-C."

      iex> Amanogawa.HistoricalDate.Formatter.format(Amanogawa.HistoricalDate.new!(%{year: -489, precision: 9}))
      "490 av. J.-C."

      iex> Amanogawa.HistoricalDate.Formatter.format(Amanogawa.HistoricalDate.new!(%{year: -489, month: 9, day: 12, precision: 11}))
      "12 septembre 490 av. J.-C."

  """

  alias Amanogawa.HistoricalDate

  @type locale :: :fr | :en

  @fr_months ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)
  @en_months ~w(January February March April May June July August September October November December)

  @magnitude_scale %{
    0 => 1_000_000_000,
    1 => 100_000_000,
    2 => 10_000_000,
    3 => 1_000_000,
    4 => 100_000,
    5 => 10_000
  }
  @magnitude_unit_fr %{
    0 => "milliard",
    1 => "cent millions",
    2 => "dizaine de millions",
    3 => "million"
  }
  @magnitude_unit_en %{0 => "billion", 1 => "hundred million", 2 => "ten million", 3 => "million"}

  @doc """
  Formats `date` for `locale` (`:fr` by default). Never raises for a valid
  `%HistoricalDate{}`.
  """
  @spec format(HistoricalDate.t(), locale()) :: String.t()
  def format(date, locale \\ :fr)

  def format(%HistoricalDate{precision: 11} = date, locale), do: format_day(date, locale)
  def format(%HistoricalDate{precision: 10} = date, locale), do: format_month(date, locale)
  def format(%HistoricalDate{precision: 9} = date, locale), do: format_year(date, locale)
  def format(%HistoricalDate{precision: 8} = date, locale), do: format_decade(date, locale)
  def format(%HistoricalDate{precision: 7} = date, locale), do: format_century(date, locale)
  def format(%HistoricalDate{precision: 6} = date, locale), do: format_millennium(date, locale)

  def format(%HistoricalDate{precision: precision} = date, locale) when precision in 0..5,
    do: format_magnitude(date, locale)

  defp format_day(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    month_name = month_name(date.month, locale)

    body =
      case locale do
        :fr -> "#{date.day} #{month_name} #{display_year}"
        :en -> "#{month_name} #{date.day}, #{display_year}"
      end

    with_era(body, era, locale)
  end

  defp format_month(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    month_name = month_name(date.month, locale)

    body =
      case locale do
        :fr -> "#{month_name} #{display_year}"
        :en -> "#{month_name} #{display_year}"
      end

    with_era(body, era, locale)
  end

  defp format_year(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    with_era(Integer.to_string(display_year), era, locale)
  end

  defp format_decade(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    decade = Integer.floor_div(display_year, 10) * 10

    body =
      case locale do
        :fr -> "années #{decade}"
        :en -> "#{decade}s"
      end

    with_era(body, era, locale)
  end

  defp format_century(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    number = Integer.floor_div(display_year - 1, 100) + 1

    body =
      case locale do
        :fr -> "#{to_roman(number)}e siècle"
        :en -> "#{ordinal(number)} century"
      end

    with_era(body, era, locale)
  end

  defp format_millennium(date, locale) do
    {display_year, era} = era_and_display_year(date.year)
    number = Integer.floor_div(display_year - 1, 1000) + 1

    body =
      case locale do
        :fr -> "#{to_roman(number)}e millénaire"
        :en -> "#{ordinal(number)} millennium"
      end

    with_era(body, era, locale)
  end

  defp format_magnitude(date, locale) do
    years_ago = abs(date.year)
    scale = Map.fetch!(@magnitude_scale, date.precision)
    rounded = max(scale, round(years_ago / scale) * scale)

    if date.precision in [4, 5] do
      about("#{format_number(rounded, locale)} #{years_word(locale)}", locale)
    else
      count = div(rounded, scale)
      unit = magnitude_unit(count, date.precision, locale)
      about("#{format_number(count, locale)} #{unit}", locale)
    end
  end

  defp about(text, :fr), do: "il y a environ #{text}"
  defp about(text, :en), do: "about #{text} ago"

  defp years_word(:fr), do: "ans"
  defp years_word(:en), do: "years"

  defp magnitude_unit(count, precision, :fr) do
    unit = Map.fetch!(@magnitude_unit_fr, precision)
    "#{pluralize_fr(unit, count)} d'années"
  end

  # Unlike French, English does not pluralize "million"/"billion" when used
  # as a quantifier before a noun ("2 million years", never "2 millions of
  # years"): only the count itself varies, not the unit word.
  defp magnitude_unit(_count, precision, :en) do
    "#{Map.fetch!(@magnitude_unit_en, precision)} years"
  end

  defp pluralize_fr(unit, 1), do: unit
  defp pluralize_fr(unit, _count), do: unit <> "s"

  defp format_number(number, :fr), do: group_thousands(number, " ")
  defp format_number(number, :en), do: group_thousands(number, ",")

  defp group_thousands(number, separator) when number >= 0 do
    number
    |> Integer.to_string()
    |> String.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map(&(&1 |> Enum.reverse() |> List.to_string()))
    |> Enum.reverse()
    |> Enum.join(separator)
  end

  defp era_and_display_year(year) when year <= 0, do: {1 - year, :bce}
  defp era_and_display_year(year), do: {year, :ce}

  defp with_era(text, :ce, _locale), do: text
  defp with_era(text, :bce, :fr), do: text <> " av. J.-C."
  defp with_era(text, :bce, :en), do: text <> " BCE"

  defp month_name(month, :fr), do: Enum.at(@fr_months, month - 1)
  defp month_name(month, :en), do: Enum.at(@en_months, month - 1)

  defp ordinal(n) do
    suffix =
      cond do
        rem(n, 100) in 11..13 -> "th"
        rem(n, 10) == 1 -> "st"
        rem(n, 10) == 2 -> "nd"
        rem(n, 10) == 3 -> "rd"
        true -> "th"
      end

    "#{n}#{suffix}"
  end

  @roman_numerals [
    {1000, "M"},
    {900, "CM"},
    {500, "D"},
    {400, "CD"},
    {100, "C"},
    {90, "XC"},
    {50, "L"},
    {40, "XL"},
    {10, "X"},
    {9, "IX"},
    {5, "V"},
    {4, "IV"},
    {1, "I"}
  ]

  defp to_roman(number) when number > 0 do
    {_remaining, roman} =
      Enum.reduce(@roman_numerals, {number, ""}, fn {value, symbol}, {remaining, acc} ->
        count = div(remaining, value)
        {remaining - count * value, acc <> String.duplicate(symbol, count)}
      end)

    roman
  end
end
