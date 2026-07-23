defmodule AmanogawaWeb.Params.BorderQueryTest do
  use ExUnit.Case, async: true

  alias AmanogawaWeb.Params.BorderQuery

  describe "parse/1 happy path" do
    test "parses a well-formed year" do
      assert {:ok, %{year: 1500}} = BorderQuery.parse(%{"year" => "1500"})
    end

    test "accepts an integer-typed param (as Plug would already have cast for some adapters)" do
      assert {:ok, %{year: 1500}} = BorderQuery.parse(%{"year" => 1500})
    end

    test "accepts a negative year" do
      assert {:ok, %{year: -500}} = BorderQuery.parse(%{"year" => "-500"})
    end
  end

  describe "parse/1 limit cases: clamping" do
    test "a year below the data domain is clamped to -123000, not rejected" do
      assert {:ok, %{year: -123_000}} = BorderQuery.parse(%{"year" => "-999999999"})
    end

    test "a year above the data domain is clamped to 2024, not rejected" do
      assert {:ok, %{year: 2024}} = BorderQuery.parse(%{"year" => "3000"})
    end

    test "the domain bounds themselves pass through unchanged" do
      assert {:ok, %{year: -123_000}} = BorderQuery.parse(%{"year" => "-123000"})
      assert {:ok, %{year: 2024}} = BorderQuery.parse(%{"year" => "2024"})
    end
  end

  describe "parse/1 error cases" do
    test "a missing year returns a structured error" do
      assert {:error, %{year: [_message]}} = BorderQuery.parse(%{})
    end

    test "a non-integer year returns a structured error" do
      assert {:error, %{year: [_message]}} = BorderQuery.parse(%{"year" => "abc"})
    end

    test "an empty string year returns a structured error" do
      assert {:error, %{year: [_message]}} = BorderQuery.parse(%{"year" => ""})
    end

    test "a float-looking year returns a structured error" do
      assert {:error, %{year: [_message]}} = BorderQuery.parse(%{"year" => "1500.5"})
    end
  end
end
