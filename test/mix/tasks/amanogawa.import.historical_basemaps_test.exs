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
      assert output =~ "borders purged (previous \"historical_basemaps\" rows):"
      assert output =~ "orphan polities purged:"
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

  describe "error case: unreadable tranche file" do
    test "a tranche without a features array raises Mix.Error (non-zero exit), not a crash dump" do
      dir = tmp_dir!()
      File.write!(Path.join(dir, "world_bc5000.geojson"), ~s({"type":"NotAFeatureCollection"}))

      assert_raise Mix.Error, ~r/Import failed while reading/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [dir]) end)
      end
    end
  end

  describe "error case: anti-wipe guard" do
    test "a directory whose tranches all fail after a good import aborts, data survives" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir]) end)
      previous_count = Atlas.count_borders()
      assert previous_count > 0

      dir = tmp_dir!()

      File.write!(
        Path.join(dir, "world_bc5000.geojson"),
        ~s({"features":[{"type":"Feature","properties":{"NAME":"Broken"},"geometry":null}]})
      )

      assert_raise Mix.Error, ~r/Pass --force/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [dir]) end)
      end

      assert Atlas.count_borders() == previous_count
    end

    test "--force deliberately empties the source" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.historical_basemaps", [@fixture_dir]) end)
      assert Atlas.count_borders() > 0

      dir = tmp_dir!()

      File.write!(
        Path.join(dir, "world_bc5000.geojson"),
        ~s({"features":[{"type":"Feature","properties":{"NAME":"Broken"},"geometry":null}]})
      )

      capture_io(fn ->
        assert :ok == Mix.Task.rerun("amanogawa.import.historical_basemaps", [dir, "--force"])
      end)

      assert Atlas.count_borders() == 0
    end
  end

  defp tmp_dir! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "historical_basemaps_task_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
