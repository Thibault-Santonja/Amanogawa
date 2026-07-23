defmodule Mix.Tasks.Amanogawa.SyncTest do
  # Not async: this file temporarily overrides the global
  # ImportEvents/ImportLinks pagination config (see `setup`) so a full
  # end-to-end run through `Oban.drain_queue/2` takes exactly one page per
  # pipeline instead of walking config/test.exs's default two slices.
  use Amanogawa.DataCase

  import ExUnit.CaptureIO
  import Mox
  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.SparqlClientMock
  alias Amanogawa.Ingestion.WikipediaClient.Summary
  alias Amanogawa.Ingestion.WikipediaClientMock
  alias Amanogawa.Ingestion.Workers.ImportEvents
  alias Amanogawa.Ingestion.Workers.ImportLinks

  setup :verify_on_exit!

  setup do
    put_worker_config(ImportEvents, page_size: 100, slice_width: 100, max_qid: 100)
    put_worker_config(ImportLinks, page_size: 100, slice_width: 100, max_qid: 100)
    :ok
  end

  describe "events target: happy path" do
    test "imports events end to end, closes the sync run, and reports a summary" do
      expect_query(fn sparql ->
        assert sparql =~ "LIMIT 3"
        {:ok, events_result(["Q1", "Q2", "Q3"])}
      end)

      output =
        capture_io(fn ->
          assert :ok == Mix.Task.rerun("amanogawa.sync", ["events", "--limit", "3"])
        end)

      assert output =~ "started sync_run"
      assert output =~ "completed"
      assert output =~ "events_fetched=3"

      assert Atlas.count_events() == 3
      assert Ingestion.last_sync_run(:events).status == :completed
    end
  end

  describe "edge case: --limit 0" do
    test "starts and closes an empty run without querying anything" do
      output =
        capture_io(fn ->
          # No Mox expectation set: any query call would raise.
          assert :ok == Mix.Task.rerun("amanogawa.sync", ["events", "--limit", "0"])
        end)

      assert output =~ "completed"
      assert Atlas.count_events() == 0
      assert Ingestion.last_sync_run(:events).status == :completed
    end
  end

  describe "error case: argument validation" do
    test "raises with a usage message on an unknown target" do
      assert_raise Mix.Error, ~r/Unknown target/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["bogus"]) end)
      end
    end

    test "raises with a usage message when the target is missing" do
      assert_raise Mix.Error, ~r/Missing target/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", []) end)
      end
    end

    test "raises on a non-integer --limit" do
      assert_raise Mix.Error, ~r/Invalid option/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["events", "--limit", "abc"]) end)
      end
    end

    test "raises on an unknown option" do
      assert_raise Mix.Error, ~r/Invalid option/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["events", "--bogus"]) end)
      end
    end

    test "raises on a negative --limit" do
      assert_raise Mix.Error, ~r/non-negative integer/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["events", "--limit=-1"]) end)
      end
    end

    test "raises on too many arguments" do
      assert_raise Mix.Error, ~r/Too many arguments/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["events", "links"]) end)
      end
    end
  end

  describe "links and summaries targets: --limit 0" do
    test "the links target starts and closes an empty run" do
      output =
        capture_io(fn ->
          assert :ok == Mix.Task.rerun("amanogawa.sync", ["links", "--limit", "0"])
        end)

      assert output =~ "completed"
      assert Ingestion.last_sync_run(:links).status == :completed
    end

    test "the summaries target starts and closes an empty run" do
      output =
        capture_io(fn ->
          assert :ok == Mix.Task.rerun("amanogawa.sync", ["summaries", "--limit", "0"])
        end)

      assert output =~ "completed"
      assert Ingestion.last_sync_run(:summaries).status == :completed
    end
  end

  describe "error case: a links run failing reports the links-specific resume snippet" do
    test "prints resume_links_import in the failure message" do
      stub(SparqlClientMock, :query, fn _sparql, _opts -> {:error, :timeout} end)

      # The failure report goes through `Mix.shell().error/1` (:stderr),
      # unlike the progress/summary reports above (`Mix.shell().info/1`,
      # :stdio): captured separately.
      stderr =
        capture_io(:stderr, fn ->
          assert_raise Mix.Error, ~r/Sync stopped/, fn ->
            Mix.Task.rerun("amanogawa.sync", ["links"])
          end
        end)

      assert stderr =~ "resume_links_import"
      assert Ingestion.last_sync_run(:links).status == :failed
    end
  end

  describe "error case: a run of the same kind is already in progress" do
    test "raises instead of starting a second concurrent run" do
      {:ok, _already_running} = Ingestion.start_events_import()

      assert_raise Mix.Error, ~r/already running/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["events"]) end)
      end
    end
  end

  describe "all: ordering" do
    test "chains events, then links, then summaries, each starting after the previous closes" do
      expect_query(fn _sparql -> {:ok, events_result(["Q1", "Q2"])} end)
      expect_query(fn _sparql -> {:ok, links_result("Q1", "Q2")} end)
      # No WikipediaClientMock stub: Q1/Q2 carry no wiki_url_fr/en (the
      # minimal fixture bindings above never set them), so no event is
      # eligible and the summaries run closes on an empty selection.

      output = capture_io(fn -> assert :ok == Mix.Task.rerun("amanogawa.sync", ["all"]) end)

      assert output =~ "[events]"
      assert output =~ "[links]"
      assert output =~ "[summaries]"

      events_run = Ingestion.last_sync_run(:events)
      links_run = Ingestion.last_sync_run(:links)
      summaries_run = Ingestion.last_sync_run(:summaries)

      assert events_run.status == :completed
      assert links_run.status == :completed
      assert summaries_run.status == :completed

      assert DateTime.compare(events_run.finished_at, links_run.started_at) in [:lt, :eq]
      assert DateTime.compare(links_run.finished_at, summaries_run.started_at) in [:lt, :eq]

      assert Atlas.count_events() == 2
      assert Atlas.count_event_links() == 1
    end
  end

  describe "all: a failed step stops the chain before the next one starts" do
    test "closes the events run failed and never starts links or summaries" do
      stub(SparqlClientMock, :query, fn _sparql, _opts -> {:error, :timeout} end)

      assert_raise Mix.Error, ~r/Sync stopped/, fn ->
        capture_io(fn -> Mix.Task.rerun("amanogawa.sync", ["all"]) end)
      end

      assert Ingestion.last_sync_run(:events).status == :failed
      assert Ingestion.last_sync_run(:links) == nil
      assert Ingestion.last_sync_run(:summaries) == nil
    end
  end

  describe "all: dry-run" do
    test "walks every step and reports non-zero counters, but writes nothing" do
      preloaded =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Preloaded",
          sitelink_count: 1
        })

      expect_query(fn _sparql -> {:ok, events_result(["Q1", "Q2"])} end)
      expect_query(fn _sparql -> {:ok, links_result("Q1", "Q2")} end)

      expect(WikipediaClientMock, :fetch_summary, fn :fr, "Preloaded" ->
        {:ok, %Summary{title: "T", extract: "Extrait", article_url: "u", lang: :fr}}
      end)

      output =
        capture_io(fn -> assert :ok == Mix.Task.rerun("amanogawa.sync", ["all", "--dry-run"]) end)

      assert output =~ "events_fetched=2"
      assert output =~ "links_fetched="
      assert output =~ "fetched=1"

      # Only the fixture inserted before the run exists: dry-run never
      # wrote the events/links this run fetched, nor the summary it
      # enriched.
      assert Atlas.count_events() == 1
      assert Atlas.count_event_links() == 0
      assert Atlas.get_event_by_qid(preloaded.qid).extract_fr == nil
    end
  end

  describe "Oban Cron configuration" do
    test "the base config carries the three monthly cron entries feeding ScheduledSync" do
      oban_config = read_oban_config(:prod)

      assert {Oban.Plugins.Cron, cron_opts} =
               Enum.find(oban_config[:plugins], &match?({Oban.Plugins.Cron, _}, &1))

      kinds =
        Enum.map(cron_opts[:crontab], fn {_expr, worker, opts} ->
          assert worker == Amanogawa.Ingestion.Workers.ScheduledSync
          opts[:args]["kind"]
        end)

      assert kinds == ["events", "links", "summaries"]
    end

    test "the test config never schedules the cron plugin" do
      assert Application.get_env(:amanogawa, Oban)[:plugins] == false
      assert read_oban_config(:test)[:plugins] == false
    end
  end

  # --- helpers ---------------------------------------------------------

  defp put_worker_config(module, opts) do
    previous = Application.get_env(:amanogawa, module, [])
    Application.put_env(:amanogawa, module, opts)
    on_exit(fn -> Application.put_env(:amanogawa, module, previous) end)
  end

  defp expect_query(fun) do
    expect(SparqlClientMock, :query, fn sparql, _opts -> fun.(sparql) end)
  end

  defp events_result(qids) do
    %Result{variables: [], bindings: Enum.map(qids, &event_binding/1)}
  end

  defp event_binding(qid) do
    %{
      "e" => uri("http://www.wikidata.org/entity/#{qid}"),
      "beginToken" => literal("1900-01-01T00:00:00Z|9|http://www.wikidata.org/entity/Q1985727"),
      "coordDirect" => literal("POINT(2.35 48.85)")
    }
  end

  defp links_result(source_qid, target_qid) do
    %Result{
      variables: ["source", "target", "property"],
      bindings: [
        %{
          "source" => uri("http://www.wikidata.org/entity/#{source_qid}"),
          "target" => uri("http://www.wikidata.org/entity/#{target_qid}"),
          "property" => literal("P361")
        }
      ]
    }
  end

  defp uri(value), do: %{value: value, type: :uri, datatype: nil, lang: nil}
  defp literal(value), do: %{value: value, type: :literal, datatype: nil, lang: nil}

  defp read_oban_config(env) do
    path = Path.join(File.cwd!(), "config/config.exs")
    path |> Config.Reader.read!(env: env) |> get_in([:amanogawa, Oban])
  end
end
