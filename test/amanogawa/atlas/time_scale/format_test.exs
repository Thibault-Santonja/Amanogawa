defmodule Amanogawa.Atlas.TimeScale.FormatTest do
  use ExUnit.Case, async: true

  doctest Amanogawa.Atlas.TimeScale.Format

  alias Amanogawa.Atlas.TimeScale.Format

  @fixture_path Path.join([
                  __DIR__,
                  "..",
                  "..",
                  "..",
                  "support",
                  "fixtures",
                  "time_scale",
                  "labels.json"
                ])

  defp fixture do
    @fixture_path |> File.read!() |> Jason.decode!()
  end

  describe "format_axis_year/2 against the shared fixture" do
    test "every case matches its expected label" do
      %{"cases" => cases} = fixture()

      for %{"year" => year, "step" => step, "expected" => expected} <- cases do
        assert Format.format_axis_year(year, step) == expected
      end
    end

    test "the fixture covers every documented regime" do
      %{"cases" => cases} = fixture()
      labels = Enum.map(cases, & &1["expected"])

      assert Enum.any?(labels, &String.ends_with?(&1, "ka BP"))
      assert Enum.any?(labels, &String.contains?(&1, "s. av. J.-C."))
      assert Enum.any?(labels, &String.ends_with?(&1, "s."))
      assert Enum.any?(labels, &(&1 == "1969"))

      assert Enum.any?(
               labels,
               &(String.ends_with?(&1, "av. J.-C.") and not String.contains?(&1, "s."))
             )
    end
  end

  describe "format_axis_year/2 happy path" do
    test "ka BP regime rounds to the nearest thousand" do
      assert Format.format_axis_year(-98_050, 1_000) == "100 ka BP"
      # The BP threshold (-10_000) is itself already ~12 ka BP (BP =
      # 1950 - year): the ka BP regime never produces a smaller value than
      # that at its own boundary.
      assert Format.format_axis_year(-10_000, 1_000) == "12 ka BP"
    end

    test "century regime handles both eras" do
      assert Format.format_axis_year(-750, 100) == "VIIIe s. av. J.-C."
      assert Format.format_axis_year(1100, 100) == "XIIe s."
    end

    test "plain year regime handles both eras" do
      assert Format.format_axis_year(1969, 1) == "1969"
      assert Format.format_axis_year(-489, 1) == "490 av. J.-C."
    end
  end

  describe "format_axis_year/3 templates (F04 quality finding m6)" do
    test "renders through caller-provided templates in every regime" do
      templates = %{ka_bp: "%{ka} ka BP", century: "%{century}th c.", bce: "%{text} BCE"}

      assert Format.format_axis_year(-98_050, 1_000, templates) == "100 ka BP"
      assert Format.format_axis_year(-750, 100, templates) == "VIIIth c. BCE"
      assert Format.format_axis_year(1100, 100, templates) == "XIIth c."
      assert Format.format_axis_year(-489, 1, templates) == "490 BCE"
      assert Format.format_axis_year(1969, 1, templates) == "1969"
    end

    test "the /2 arity uses the French default templates" do
      assert Format.default_templates() == %{
               ka_bp: "%{ka} ka BP",
               century: "%{century}e s.",
               bce: "%{text} av. J.-C."
             }

      assert Format.format_axis_year(-489, 1) ==
               Format.format_axis_year(-489, 1, Format.default_templates())
    end
  end

  describe "format_axis_year/2 edge cases" do
    test "year 0 (1 av. J.-C.) is not rendered as a bare 0" do
      assert Format.format_axis_year(0, 1) == "1 av. J.-C."
    end

    test "the regime is picked from step, not an implicit zoom level" do
      # The exact same year renders differently depending on the caller's
      # tick step: the axis, not the year, decides the granularity.
      assert Format.format_axis_year(1100, 1) == "1100"
      assert Format.format_axis_year(1100, 100) == "XIIe s."
    end
  end
end
