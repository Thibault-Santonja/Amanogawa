defmodule Amanogawa.HistoricalDateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Amanogawa.HistoricalDateGenerators

  alias Amanogawa.HistoricalDate

  describe "min_year/0 and max_year/0" do
    test "min_year is the exact lower bound enforced by changeset/2" do
      assert HistoricalDate.min_year() == -13_800_000_000

      assert HistoricalDate.changeset(%HistoricalDate{}, %{
               year: HistoricalDate.min_year(),
               precision: 0
             }).valid?

      refute HistoricalDate.changeset(%HistoricalDate{}, %{
               year: HistoricalDate.min_year() - 1,
               precision: 0
             }).valid?
    end

    test "max_year is the exact upper bound enforced by changeset/2" do
      assert HistoricalDate.max_year() == 3_000

      assert HistoricalDate.changeset(%HistoricalDate{}, %{
               year: HistoricalDate.max_year(),
               precision: 0
             }).valid?

      refute HistoricalDate.changeset(%HistoricalDate{}, %{
               year: HistoricalDate.max_year() + 1,
               precision: 0
             }).valid?
    end
  end

  describe "changeset/2 happy path" do
    test "accepts a full date (day precision)" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{
          year: 1789,
          month: 7,
          day: 14,
          precision: 11
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :month) == 7
      assert Ecto.Changeset.get_field(changeset, :day) == 14
    end

    test "accepts a year-only date" do
      changeset = HistoricalDate.changeset(%HistoricalDate{}, %{year: -489, precision: 9})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :month) == nil
      assert Ecto.Changeset.get_field(changeset, :day) == nil
    end
  end

  describe "changeset/2 edge cases" do
    test "year 0 (1 BCE) is accepted" do
      assert {:ok, %HistoricalDate{year: 0}} = HistoricalDate.new(%{year: 0, precision: 9})
    end

    test "a very negative year is accepted (deep prehistory)" do
      assert {:ok, %HistoricalDate{year: -123_000}} =
               HistoricalDate.new(%{year: -123_000, precision: 6})
    end

    test "compare/2 between precision 9 and precision 11 of the same year is equal" do
      {:ok, coarse} = HistoricalDate.new(%{year: 1789, precision: 9})
      {:ok, precise} = HistoricalDate.new(%{year: 1789, month: 7, day: 14, precision: 11})

      assert HistoricalDate.compare(coarse, precise) == :eq
      assert HistoricalDate.compare(precise, coarse) == :eq
    end
  end

  describe "changeset/2 error cases" do
    test "precision out of 0..11 is rejected" do
      changeset = HistoricalDate.changeset(%HistoricalDate{}, %{year: 1789, precision: 12})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).precision
    end

    test "day without month is rejected" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{year: 1789, day: 14, precision: 11})

      refute changeset.valid?
      assert "is required when day is present" in errors_on(changeset).month
    end

    test "month 13 is rejected" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{
          year: 1789,
          month: 13,
          day: 1,
          precision: 11
        })

      refute changeset.valid?
      assert "must be between 1 and 12" in errors_on(changeset).month
    end

    test "day 32 is rejected" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{
          year: 1789,
          month: 1,
          day: 32,
          precision: 11
        })

      refute changeset.valid?
      assert "must be between 1 and 31" in errors_on(changeset).day
    end

    test "month and day given with precision <= 9 are truncated, not rejected" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{year: 1789, month: 7, day: 14, precision: 9})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :month) == nil
      assert Ecto.Changeset.get_field(changeset, :day) == nil
    end

    test "day given with precision 10 is truncated, month kept" do
      changeset =
        HistoricalDate.changeset(%HistoricalDate{}, %{
          year: 1789,
          month: 7,
          day: 14,
          precision: 10
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :month) == 7
      assert Ecto.Changeset.get_field(changeset, :day) == nil
    end
  end

  describe "changeset/2 limit cases" do
    test "precision 0 and 11 are the accepted bounds" do
      assert {:ok, _} = HistoricalDate.new(%{year: -1_000_000, precision: 0})
      assert {:ok, _} = HistoricalDate.new(%{year: 2024, month: 1, day: 1, precision: 11})
    end

    test "month 12 and day 31 are accepted" do
      assert {:ok, %HistoricalDate{month: 12, day: 31}} =
               HistoricalDate.new(%{year: 2024, month: 12, day: 31, precision: 11})
    end

    test "the year bounds [-13_800_000_000, 3000] are accepted, one step beyond is rejected" do
      assert {:ok, _} = HistoricalDate.new(%{year: -13_800_000_000, precision: 0})
      assert {:ok, _} = HistoricalDate.new(%{year: 3000, precision: 9})

      assert {:error, %Ecto.Changeset{} = too_deep} =
               HistoricalDate.new(%{year: -13_800_000_001, precision: 0})

      assert {:error, %Ecto.Changeset{} = too_far} =
               HistoricalDate.new(%{year: 3001, precision: 9})

      assert Keyword.has_key?(too_deep.errors, :year)
      assert Keyword.has_key?(too_far.errors, :year)
    end
  end

  describe "new/1 and new!/1" do
    test "new/1 returns a tagged error for invalid attributes" do
      assert {:error, %Ecto.Changeset{}} = HistoricalDate.new(%{year: 1789, precision: 42})
    end

    test "new!/1 raises for invalid attributes" do
      assert_raise Ecto.InvalidChangesetError, fn ->
        HistoricalDate.new!(%{year: 1789, precision: 42})
      end
    end
  end

  describe "sort_key/1 and compare/2 concrete examples" do
    test "sort_key orders by year, month NULLS FIRST, day NULLS FIRST" do
      year_only = HistoricalDate.new!(%{year: 1789, precision: 9})
      with_month = HistoricalDate.new!(%{year: 1789, month: 3, precision: 10})
      with_day = HistoricalDate.new!(%{year: 1789, month: 3, day: 10, precision: 11})

      sorted =
        [with_day, year_only, with_month]
        |> Enum.sort_by(&HistoricalDate.sort_key/1)

      assert sorted == [year_only, with_month, with_day]
    end
  end

  property "sorting by sort_key/1 produces the (year, month NULLS FIRST, day NULLS FIRST) order" do
    check all dates <- list_of(historical_date(), max_length: 20), max_runs: 50 do
      sorted = Enum.sort_by(dates, &HistoricalDate.sort_key/1)
      keys = Enum.map(sorted, &HistoricalDate.sort_key/1)

      assert keys == Enum.sort(keys)
    end
  end

  property "invariant: precision <= 9 implies no month/day, precision 10 implies no day" do
    check all date <- historical_date() do
      case date.precision do
        p when p <= 9 -> assert is_nil(date.month) and is_nil(date.day)
        10 -> assert is_nil(date.day)
        11 -> :ok
      end
    end
  end

  property "compare/2 is antisymmetric" do
    check all date1 <- historical_date(), date2 <- historical_date() do
      case HistoricalDate.compare(date1, date2) do
        :eq -> assert HistoricalDate.compare(date2, date1) == :eq
        :lt -> assert HistoricalDate.compare(date2, date1) == :gt
        :gt -> assert HistoricalDate.compare(date2, date1) == :lt
      end
    end
  end

  property "compare/2 is transitive when all three dates are fully comparable (precision >= 10)" do
    check all year <- year(),
              month1 <- integer(1..12),
              month2 <- integer(1..12),
              month3 <- integer(1..12) do
      date1 = HistoricalDate.new!(%{year: year, month: month1, precision: 10})
      date2 = HistoricalDate.new!(%{year: year, month: month2, precision: 10})
      date3 = HistoricalDate.new!(%{year: year, month: month3, precision: 10})

      if HistoricalDate.compare(date1, date2) == :lt and
           HistoricalDate.compare(date2, date3) == :lt do
        assert HistoricalDate.compare(date1, date3) == :lt
      end
    end
  end

  defp errors_on(changeset), do: Amanogawa.DataCase.errors_on(changeset)
end
