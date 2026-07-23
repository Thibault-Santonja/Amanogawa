defmodule Mix.Tasks.Amanogawa.Import.CliopatriaTest do
  use Amanogawa.DataCase

  import ExUnit.CaptureIO

  alias Amanogawa.Atlas

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "cliopatria", "sample.geojson"])

  describe "happy path" do
    test "imports the fixture and prints a summary consistent with the database state" do
      output =
        capture_io(fn ->
          assert :ok == Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture])
        end)

      assert output =~ "importing"
      assert output =~ "borders purged (previous \"cliopatria\" rows):"
      assert output =~ "orphan polities purged:"
      assert output =~ "borders inserted:"
      assert output =~ "3"

      assert Atlas.count_borders() == 3
    end

    test "warns about boundary-year pairs (to_year == from_year on the same polity)" do
      # The sample fixture carries two consecutive Roman Empire polygons
      # with ToYear 395 and FromYear 395: exactly one touching pair.
      output = capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture]) end)

      assert output =~ "warning: 1 pair(s)"
      assert output =~ "share a boundary year"
    end
  end

  describe "idempotence" do
    test "running the task twice on the same file leaves the same final row count" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture]) end)
      first_count = Atlas.count_borders()

      capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture]) end)

      assert Atlas.count_borders() == first_count
    end
  end

  describe "error case: argument validation" do
    test "raises when PATH is missing" do
      assert_raise Mix.Error, ~r/Missing PATH/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", []) end)
      end
    end

    test "raises when PATH does not exist" do
      assert_raise Mix.Error, ~r/File not found/, fn ->
        capture_io(fn ->
          Mix.Task.rerun("amanogawa.import.cliopatria", ["/nonexistent.geojson"])
        end)
      end
    end

    test "raises on too many arguments" do
      assert_raise Mix.Error, ~r/Too many arguments/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture, "extra"]) end)
      end
    end

    test "raises on an unknown switch" do
      assert_raise Mix.Error, ~r/Unknown option/, fn ->
        capture_io(fn ->
          Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture, "--unknown"])
        end)
      end
    end
  end

  describe "error case: unreadable FeatureCollection" do
    test "a file without a features array raises Mix.Error (non-zero exit), not a crash dump" do
      path = write_tmp!(~s({"type":"NotAFeatureCollection"}))

      assert_raise Mix.Error, ~r/Import failed while reading/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [path]) end)
      end
    end

    test "a truncated file raises Mix.Error with the scanner's message" do
      path = write_tmp!(~s({"features":[{"type":"Feature"))

      assert_raise Mix.Error, ~r/ended while still in/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [path]) end)
      end
    end
  end

  describe "error case: anti-wipe guard" do
    test "a wrong file after a good import aborts with a clear message, data survives" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture]) end)
      previous_count = Atlas.count_borders()
      assert previous_count > 0

      bad_path = write_tmp!(~s({"features":[{"type":"Feature","properties":{},"geometry":null}]}))

      assert_raise Mix.Error, ~r/Pass --force/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [bad_path]) end)
      end

      assert Atlas.count_borders() == previous_count
    end

    test "--force deliberately empties the source on the same wrong file" do
      capture_io(fn -> Mix.Task.rerun("amanogawa.import.cliopatria", [@fixture]) end)
      assert Atlas.count_borders() > 0

      bad_path = write_tmp!(~s({"features":[{"type":"Feature","properties":{},"geometry":null}]}))

      capture_io(fn ->
        assert :ok == Mix.Task.rerun("amanogawa.import.cliopatria", [bad_path, "--force"])
      end)

      assert Atlas.count_borders() == 0
    end
  end

  defp write_tmp!(content) do
    path =
      Path.join(
        System.tmp_dir!(),
        "cliopatria_task_test_#{System.unique_integer([:positive])}.geojson"
      )

    File.write!(path, content)
    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end
end
