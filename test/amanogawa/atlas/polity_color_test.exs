defmodule Amanogawa.Atlas.PolityColorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Amanogawa.Atlas.PolityColor

  alias Amanogawa.Atlas.PolityColor

  describe "for_name/1 happy path" do
    test "returns a valid hsl() string, identical across repeated calls" do
      first = PolityColor.for_name("Roman Empire")
      second = PolityColor.for_name("Roman Empire")

      assert first == second
      assert first =~ ~r/^hsl\(\d+, 45%, 55%\)$/
    end

    test "the fixed example is stable (regression guard for the hash algorithm)" do
      assert PolityColor.for_name("Roman Empire") == "hsl(346, 45%, 55%)"
    end
  end

  describe "for_name/1 edge cases" do
    test "unicode names (accents, ideograms) produce a valid color" do
      for name <- ["Côte d'Ivoire", "北京", "Österreich", "Ελλάδα"] do
        assert PolityColor.for_name(name) =~ ~r/^hsl\(\d+, 45%, 55%\)$/
      end
    end

    test "a single-character name produces a valid color" do
      assert PolityColor.for_name("A") =~ ~r/^hsl\(\d+, 45%, 55%\)$/
    end

    test "a very long name produces a valid color" do
      long_name = String.duplicate("x", 5000)
      assert PolityColor.for_name(long_name) =~ ~r/^hsl\(\d+, 45%, 55%\)$/
    end

    test "an empty name produces a valid color" do
      assert PolityColor.for_name("") =~ ~r/^hsl\(\d+, 45%, 55%\)$/
    end

    test "two distinct common names produce distinct hues (fixed cases)" do
      assert PolityColor.hue_for("Roman Empire") != PolityColor.hue_for("Ottoman Empire")
      assert PolityColor.for_name("Roman Empire") != PolityColor.for_name("Ottoman Empire")
    end
  end

  describe "hue_for/1 property" do
    property "the hue is always in [0, 360) and deterministic for any binary name" do
      check all(name <- StreamData.binary()) do
        hue = PolityColor.hue_for(name)

        assert is_integer(hue)
        assert hue >= 0
        assert hue < 360
        assert PolityColor.hue_for(name) == hue
      end
    end
  end
end
