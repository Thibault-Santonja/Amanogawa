defmodule Amanogawa.Ingestion.Workers.EnrichSummariesTest do
  use Amanogawa.DataCase, async: true

  import ExUnit.CaptureLog
  import Mox
  import Amanogawa.AtlasFixtures

  alias Amanogawa.Atlas
  alias Amanogawa.Atlas.Event
  alias Amanogawa.Ingestion
  alias Amanogawa.Ingestion.SyncRun
  alias Amanogawa.Ingestion.WikipediaClient.Summary
  alias Amanogawa.Ingestion.WikipediaClientMock
  alias Amanogawa.Ingestion.Workers.EnrichSummaries

  setup :verify_on_exit!

  # Matches config/test.exs: batch_size: 2, inter_batch_delay_seconds: 0.

  describe "integration: full run across fr, en-fallback, article-less, and freshly cached events" do
    test "enriches only the eligible events in importance order, applies the en fallback, ignores the rest, and closes with exact counters" do
      top =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 300
        })

      second =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_d_Azincourt",
          sitelink_count: 200
        })

      third_en_only =
        event_fixture(%{
          wiki_url_en: "https://en.wikipedia.org/wiki/Third_Council_of_the_Lateran",
          sitelink_count: 100
        })

      without_article = event_fixture(%{sitelink_count: 999})

      freshly_cached =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Deja_enrichi",
          sitelink_count: 999,
          extract_fetched_at: utc_now()
        })

      # Consumed FIFO: this order asserts the processing order is exactly
      # sitelink_count descending, across the two batches (batch_size: 2)
      # it takes to walk three eligible events.
      expect(WikipediaClientMock, :fetch_summary, fn :fr, "Bataille_de_Marathon" ->
        {:ok, summary_fixture(:fr, "https://fr.wikipedia.org/wiki/Bataille_de_Marathon")}
      end)

      expect(WikipediaClientMock, :fetch_summary, fn :fr, "Bataille_d_Azincourt" ->
        {:ok, summary_fixture(:fr, "https://fr.wikipedia.org/wiki/Bataille_d_Azincourt", nil)}
      end)

      expect(WikipediaClientMock, :fetch_summary, fn :en, "Third_Council_of_the_Lateran" ->
        {:ok, summary_fixture(:en, "https://en.wikipedia.org/wiki/Third_Council_of_the_Lateran")}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(sync_run.id)

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.finished_at != nil
      assert final.counts == %{"fetched" => 3, "enriched_fr" => 2, "enriched_en" => 1}

      updated_top = Atlas.get_event_by_qid(top.qid)
      assert updated_top.extract_fr == "Extrait fr"
      assert updated_top.thumbnail_url == "https://example.org/thumb.jpg"

      assert updated_top.extract_attribution == %{
               "article_url" => "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
               "license" => "CC BY-SA 4.0",
               "lang" => "fr"
             }

      assert updated_top.extract_fetched_at != nil

      updated_second = Atlas.get_event_by_qid(second.qid)
      assert updated_second.extract_fr == "Extrait fr"
      assert updated_second.thumbnail_url == nil

      updated_third = Atlas.get_event_by_qid(third_en_only.qid)
      assert updated_third.extract_en == "Extract en"
      assert updated_third.extract_fr == nil

      untouched_without_article = Atlas.get_event_by_qid(without_article.qid)
      assert untouched_without_article.extract_fr == nil
      assert untouched_without_article.extract_en == nil
      assert untouched_without_article.extract_fetched_at == nil

      untouched_fresh = Atlas.get_event_by_qid(freshly_cached.qid)
      assert untouched_fresh.extract_fr == nil
    end
  end

  describe "integration: cache" do
    test "relaunching enrichment immediately makes zero calls to the client: every extract_fetched_at is fresh" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, first_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(first_run.id)
      assert Ingestion.get_sync_run(first_run.id).counts["fetched"] == 1

      # No Mox expectation set here: a client call would raise "unexpected
      # call" and fail the test.
      {:ok, second_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(second_run.id)

      assert Ingestion.get_sync_run(second_run.id).status == :completed
      assert Ingestion.get_sync_run(second_run.id).counts == %{}
    end

    test "an event whose cache is older than max_age_days is re-fetched" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10,
          extract_fetched_at: days_ago(31)
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(sync_run.id)

      assert Ingestion.get_sync_run(sync_run.id).counts == %{"fetched" => 1, "enriched_fr" => 1}
    end

    test "max_age_days can be overridden per run" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10,
          extract_fetched_at: days_ago(2)
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment(max_age_days: 1)
      run_to_completion(sync_run.id, max_age_days: 1)

      assert Ingestion.get_sync_run(sync_run.id).counts == %{"fetched" => 1, "enriched_fr" => 1}
    end
  end

  describe "integration: not_found" do
    test "a 404 article is marked attempted without an extract, and stays excluded until the cache expires" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Article_Inexistant",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title -> {:error, :not_found} end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(sync_run.id)

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts == %{"fetched" => 1, "not_found" => 1}

      updated = Atlas.get_event_by_qid(event.qid)
      assert updated.extract_fr == nil
      assert updated.extract_fetched_at != nil

      # No Mox expectation set here: the fresh (just-stamped) cache must
      # exclude the event from the next run without another client call.
      {:ok, second_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(second_run.id)
      assert Ingestion.get_sync_run(second_run.id).counts == %{}
    end
  end

  describe "integration: rate limit" do
    test "a rate-limited fetch snoozes the job instead of failing it, and the run stays running" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:error, {:rate_limited, 60}}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      assert {:snooze, 60} == perform_job(EnrichSummaries, job_args(sync_run.id))

      running = Ingestion.get_sync_run(sync_run.id)
      assert running.status == :running
      assert running.counts == %{}

      untouched = Atlas.get_event_by_qid(event.qid)
      assert untouched.extract_fetched_at == nil
    end

    test "a rate-limited event stops the batch but keeps events already enriched in it" do
      first =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 20
        })

      second =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_d_Azincourt",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, first.wiki_url_fr)}
      end)

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:error, {:rate_limited, nil}}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      assert {:snooze, 60} == perform_job(EnrichSummaries, job_args(sync_run.id))

      running = Ingestion.get_sync_run(sync_run.id)
      assert running.status == :running
      assert running.counts == %{"fetched" => 1, "enriched_fr" => 1}

      enriched_first = Atlas.get_event_by_qid(first.qid)
      assert enriched_first.extract_fr != nil

      still_pending_second = Atlas.get_event_by_qid(second.qid)
      assert still_pending_second.extract_fetched_at == nil
    end
  end

  describe "integration: transient error" do
    test "a batch where every event fails transiently closes the run :failed instead of looping on the same selection" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title -> {:error, :timeout} end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      log =
        capture_log(fn ->
          assert :ok == perform_job(EnrichSummaries, job_args(sync_run.id))
        end)

      assert log =~ "EnrichSummaries fetch failed for #{event.qid}"

      # A transient error is not horodated (unlike :not_found): the event
      # stays eligible. But a whole batch without any progression would
      # re-select the exact same events forever, so the run closes :failed
      # with an explicit error instead of chaining.
      failed = Ingestion.get_sync_run(sync_run.id)
      assert failed.status == :failed
      assert failed.last_error =~ "no progression"
      assert failed.counts == %{"fetched" => 1, "errors" => 1}

      untouched = Atlas.get_event_by_qid(event.qid)
      assert untouched.extract_fr == nil
      assert untouched.extract_fetched_at == nil
    end

    test "a batch mixing one success and one transient error keeps chaining (progression happened)" do
      first =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 20
        })

      _second =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_d_Azincourt",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, "Bataille_de_Marathon" ->
        {:ok, summary_fixture(:fr, first.wiki_url_fr)}
      end)

      expect(WikipediaClientMock, :fetch_summary, fn :fr, "Bataille_d_Azincourt" ->
        {:error, :timeout}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      capture_log(fn ->
        assert :ok == perform_job(EnrichSummaries, job_args(sync_run.id))
      end)

      running = Ingestion.get_sync_run(sync_run.id)
      assert running.status == :running
      assert running.counts == %{"fetched" => 2, "enriched_fr" => 1, "errors" => 1}
    end
  end

  describe "integration: permanent error (4xx, decode_error)" do
    test "a 4xx other than 429 stamps extract_fetched_at so the event leaves the selection until the cache expires" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:error, {:http_error, 400}}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      log =
        capture_log(fn ->
          run_to_completion(sync_run.id)
        end)

      assert log =~ "permanent fetch failure for #{event.qid}"

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts == %{"fetched" => 1, "errors" => 1}

      marked = Atlas.get_event_by_qid(event.qid)
      assert marked.extract_fr == nil
      assert marked.extract_fetched_at != nil

      # No Mox expectation set here: the freshly stamped cache must exclude
      # the event from the next run without another client call.
      {:ok, second_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(second_run.id)
      assert Ingestion.get_sync_run(second_run.id).counts == %{}
    end

    test "a decode_error is treated as permanent too" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:error, {:decode_error, :invalid_summary_shape}}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      capture_log(fn -> run_to_completion(sync_run.id) end)

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
      assert Atlas.get_event_by_qid(event.qid).extract_fetched_at != nil
    end
  end

  describe "defensive: an exception escaping the job" do
    test "an exception on the final attempt closes the run :failed with last_error before re-raising" do
      event_fixture(%{
        wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
        sitelink_count: 10
      })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title -> raise "client exploded" end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      assert_raise RuntimeError, "client exploded", fn ->
        perform_job(EnrichSummaries, job_args(sync_run.id), attempt: 5)
      end

      failed = Ingestion.get_sync_run(sync_run.id)
      assert failed.status == :failed
      assert failed.last_error =~ "client exploded"
    end
  end

  describe "integration: upsert" do
    test "a Wikidata upsert replayed after enrichment touches neither extract, thumbnail, nor attribution" do
      event =
        event_fixture(%{
          qid: "Q9998887",
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10,
          label_fr: "Ancien libellé"
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment()
      run_to_completion(sync_run.id)

      enriched = Atlas.get_event_by_qid("Q9998887")
      assert enriched.extract_fr != nil

      {:ok, _} =
        Atlas.upsert_events([wikidata_replay_attrs(enriched, label_fr: "Nouveau libellé")])

      replayed = Atlas.get_event_by_qid("Q9998887")
      assert replayed.label_fr == "Nouveau libellé"
      assert replayed.extract_fr == enriched.extract_fr
      assert replayed.thumbnail_url == enriched.thumbnail_url
      assert replayed.extract_attribution == enriched.extract_attribution
      assert replayed.extract_fetched_at == enriched.extract_fetched_at
    end
  end

  describe "edge case: dry_run" do
    test "walks one batch and counts, but never writes to Atlas, and closes after that single batch" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment(dry_run: true)

      assert :ok == perform_job(EnrichSummaries, job_args(sync_run.id, dry_run: true))

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts == %{"fetched" => 1, "enriched_fr" => 1}

      untouched = Atlas.get_event_by_qid(event.qid)
      assert untouched.extract_fr == nil
      assert untouched.extract_fetched_at == nil
    end
  end

  describe "limit case: a global limit smaller than a batch closes the run once reached" do
    test "requests only up to the remaining limit and closes once it is reached" do
      event =
        event_fixture(%{
          wiki_url_fr: "https://fr.wikipedia.org/wiki/Bataille_de_Marathon",
          sitelink_count: 10
        })

      expect(WikipediaClientMock, :fetch_summary, fn :fr, _title ->
        {:ok, summary_fixture(:fr, event.wiki_url_fr)}
      end)

      {:ok, sync_run} = Ingestion.start_summaries_enrichment(limit: 1)
      run_to_completion(sync_run.id, limit: 1)

      final = Ingestion.get_sync_run(sync_run.id)
      assert final.status == :completed
      assert final.counts["fetched"] == 1
    end
  end

  describe "defensive: redelivery of a job for a run that is not (or no longer) actionable" do
    test "a job for an already-closed run is a safe no-op (no client call, no state change)" do
      {:ok, sync_run} = Ingestion.start_summaries_enrichment()

      sync_run
      |> SyncRun.close_changeset(%{status: :completed})
      |> Repo.update!()

      # No Mox expectation set: any client call would raise.
      assert :ok == perform_job(EnrichSummaries, job_args(sync_run.id))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end

    test "a running run whose counts already reached the given limit closes without querying" do
      {:ok, sync_run} = Ingestion.start_summaries_enrichment(limit: 5)

      sync_run
      |> SyncRun.progress_changeset(%{counts: %{"fetched" => 5}})
      |> Repo.update!()

      # No Mox expectation set: any client call would raise.
      assert :ok == perform_job(EnrichSummaries, job_args(sync_run.id, limit: 5))

      assert Ingestion.get_sync_run(sync_run.id).status == :completed
    end
  end

  # --- helpers ---------------------------------------------------------

  defp job_args(sync_run_id, opts \\ []) do
    %{
      "sync_run_id" => sync_run_id,
      "limit" => Keyword.get(opts, :limit),
      "dry_run" => Keyword.get(opts, :dry_run, false),
      "max_age_days" => Keyword.get(opts, :max_age_days)
    }
  end

  # Repeatedly performs the next batch job until the run leaves :running,
  # bounded so a logic bug (infinite chaining) fails the test instead of
  # hanging it. `opts` must mirror whatever `Ingestion.start_summaries_enrichment/1`
  # opts started the run with (limit, max_age_days): each simulated job
  # execution rebuilds its args from scratch rather than reading the real
  # enqueued job, so a mismatch here would silently drop them mid-run.
  defp run_to_completion(sync_run_id, opts \\ [], max_iterations \\ 20) do
    :ok =
      Enum.reduce_while(1..max_iterations, :ok, fn _, :ok ->
        case Ingestion.get_sync_run(sync_run_id) do
          %SyncRun{status: :running} ->
            assert :ok == perform_job(EnrichSummaries, job_args(sync_run_id, opts))
            {:cont, :ok}

          _closed ->
            {:halt, :ok}
        end
      end)

    refute Ingestion.get_sync_run(sync_run_id).status == :running
  end

  defp summary_fixture(lang, article_url, thumbnail_url \\ "https://example.org/thumb.jpg") do
    %Summary{
      title: "Titre",
      extract: extract_text(lang),
      thumbnail_url: thumbnail_url,
      article_url: article_url,
      lang: lang
    }
  end

  defp extract_text(:fr), do: "Extrait fr"
  defp extract_text(:en), do: "Extract en"

  defp wikidata_replay_attrs(%Event{} = event, overrides) do
    %{
      qid: event.qid,
      label_fr: Keyword.get(overrides, :label_fr, event.label_fr),
      label_en: event.label_en,
      description_fr: event.description_fr,
      description_en: event.description_en,
      wiki_url_fr: event.wiki_url_fr,
      wiki_url_en: event.wiki_url_en,
      kind: event.kind,
      geom: event.geom,
      location_source: event.location_source,
      sitelink_count: event.sitelink_count
    }
    |> Map.merge(Atlas.flatten_date(Event.begin_date(event), :begin))
    |> Map.merge(Atlas.flatten_date(Event.end_date(event), :end))
  end

  defp days_ago(n), do: DateTime.add(utc_now(), -n, :day)

  defp utc_now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
