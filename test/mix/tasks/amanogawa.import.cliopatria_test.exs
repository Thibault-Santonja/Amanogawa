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
      assert output =~ "borders inserted:"
      assert output =~ "3"

      assert Atlas.count_borders() == 3
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
  end
end
