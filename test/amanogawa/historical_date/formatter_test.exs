defmodule Amanogawa.HistoricalDate.FormatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.HistoricalDate.Formatter

  import Amanogawa.HistoricalDateGenerators

  alias Amanogawa.HistoricalDate
  alias Amanogawa.HistoricalDate.Formatter

  describe "day precision (11)" do
    test "formats fr with day and month" do
      date = HistoricalDate.new!(%{year: 1789, month: 7, day: 14, precision: 11})

      assert Formatter.format(date, :fr) == "14 juillet 1789"
    end

    test "formats en with day and month" do
      date = HistoricalDate.new!(%{year: 1789, month: 7, day: 14, precision: 11})

      assert Formatter.format(date, :en) == "July 14, 1789"
    end
  end

  describe "month precision (10)" do
    test "formats fr" do
      date = HistoricalDate.new!(%{year: 1789, month: 9, precision: 10})

      assert Formatter.format(date, :fr) == "septembre 1789"
    end
  end

  describe "year precision (9)" do
    test "formats a CE year plainly" do
      date = HistoricalDate.new!(%{year: 1789, precision: 9})

      assert Formatter.format(date, :fr) == "1789"
    end

    test "formats a BCE year" do
      date = HistoricalDate.new!(%{year: -489, precision: 9})

      assert Formatter.format(date, :fr) == "490 av. J.-C."
    end
  end

  describe "decade precision (8)" do
    test "formats a CE decade" do
      date = HistoricalDate.new!(%{year: 1785, precision: 8})

      assert Formatter.format(date, :fr) == "années 1780"
    end

    test "formats a BCE decade" do
      date = HistoricalDate.new!(%{year: -489, precision: 8})

      assert Formatter.format(date, :fr) == "années 490 av. J.-C."
    end
  end

  describe "century precision (7)" do
    test "formats a CE century in roman numerals" do
      date = HistoricalDate.new!(%{year: 1789, precision: 7})

      assert Formatter.format(date, :fr) == "XVIIIe siècle"
    end

    test "formats a BCE century in roman numerals" do
      date = HistoricalDate.new!(%{year: -700, precision: 7})

      assert Formatter.format(date, :fr) == "VIIIe siècle av. J.-C."
    end
  end

  describe "millennium precision (6)" do
    test "formats in roman numerals" do
      date = HistoricalDate.new!(%{year: -1500, precision: 6})

      assert Formatter.format(date, :fr) == "IIe millénaire av. J.-C."
    end
  end

  describe "orders of magnitude (precision 0-5)" do
    test "hundred thousand years scale" do
      date = HistoricalDate.new!(%{year: -100_000, precision: 4})

      assert Formatter.format(date, :fr) == "il y a environ 100 000 ans"
    end

    test "million years scale" do
      date = HistoricalDate.new!(%{year: -2_000_000, precision: 3})

      assert Formatter.format(date, :fr) == "il y a environ 2 millions d'années"
    end

    test "million years scale in english (invariant quantifier, unlike french)" do
      date = HistoricalDate.new!(%{year: -2_000_000, precision: 3})

      assert Formatter.format(date, :en) == "about 2 million years ago"
    end
  end

  property "for precision <= 9, the output contains no month name and no day number" do
    check all date <- historical_date(), date.precision <= 9, locale <- member_of([:fr, :en]) do
      formatted = Formatter.format(date, locale)

      refute String.contains?(formatted, month_names(locale))
    end
  end

  property "format/2 never raises for a valid historical date" do
    check all date <- historical_date(), locale <- member_of([:fr, :en]) do
      assert is_binary(Formatter.format(date, locale))
    end
  end

  defp month_names(:fr),
    do: ~w(janvier février mars avril mai juin juillet août septembre octobre novembre décembre)

  defp month_names(:en),
    do: ~w(January February March April May June July August September October November December)
end
