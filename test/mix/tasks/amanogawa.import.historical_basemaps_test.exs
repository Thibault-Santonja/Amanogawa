defmodule Mix.Tasks.Amanogawa.Import.HistoricalBasemapsTest do
  use Amanogawa.DataCase

  import ExUnit.CaptureIO

  alias Amanogawa.Atlas

  @fixture_dir Path.join([__DIR__, "..", "..", "support", "fixtures", "historical_basemaps"])

  describe "happy path" do
    test "imports the fixture directory and prints a summary consistent with the database state" do
      output =
        capture_io(fn ->
          assert :ok == Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir])
        end)

      assert output =~ "importing tranches"
      assert output =~ "tranches imported"
      assert output =~ "tranches excluded"
      assert output =~ "unrecognized files"

      assert Atlas.count_borders() == 3
    end
  end

  describe "idempotence" do
    test "running the task twice on the same directory leaves the same final row count" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir]) end)
      first_count = Atlas.count_borders()

      capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir]) end)

      assert Atlas.count_borders() == first_count
    end
  end

  describe "error case: argument validation" do
    test "raises when PATH is missing" do
      assert_raise Mix.Error, ~r/Missing PATH/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", []) end)
      end
    end

    test "raises when PATH is not a directory" do
      assert_raise Mix.Error, ~r/Directory not found/, fn ->
        capture_io(fn ->
          Mix.Task.rerun("amanogawa.import.historical_basemaps", ["/nonexistent_dir"])
        end)
      end
    end

    test "raises on too many arguments" do
      assert_raise Mix.Error, ~r/Too many arguments/, fn ->
        capture_io(fn ->
          Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir, "extra"])
        end)
      end
    end
  end
end
