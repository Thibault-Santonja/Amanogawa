defmodule Amanogawa.Ingestion.WikipediaClient.RestTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Amanogawa.WikipediaFixtures

  alias Amanogawa.Ingestion.WikipediaClient.Rest
  alias Amanogawa.Ingestion.WikipediaClient.Summary

  describe "fetch_summary/2 happy path" do
    test "decodes the fr fixture into a complete Summary" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
      end)

      assert {:ok, %Summary{} = summary} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")

      assert summary.title == "Bataille de Marathon"
      assert summary.lang == :fr
      assert summary.thumbnail_url =~ "upload.wikimedia.org"
      assert summary.article_url == "https://fr.wikipedia.org/wiki/Bataille_de_Marathon"
    end

    test "requests the language subdomain and the title on the summary path" do
      Req.Test.stub(Rest, fn conn ->
        assert conn.host == "fr.wikipedia.org"
        assert conn.request_path == "/api/rest_v1/page/summary/Bataille_de_Marathon"

        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
      end)

      assert {:ok, %Summary{}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "re-encodes a title with accents and apostrophes for the request path" do
      Req.Test.stub(Rest, fn conn ->
        assert conn.request_path ==
                 "/api/rest_v1/page/summary/D%C3%A9fenestration_de_Prague_%27bis%27"

        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
      end)

      assert {:ok, %Summary{}} = Rest.fetch_summary(:fr, "Défenestration_de_Prague_'bis'")
    end

    test "sends the identified User-Agent" do
      Req.Test.stub(Rest, fn conn ->
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")

        assert user_agent =~
                 ~r"^Amanogawa/[\d.]+ \(https://github\.com/Thibault-Santonja/Amanogawa; thibault\.santonja@gmail\.com\)$"

        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
      end)

      assert {:ok, %Summary{}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "logs status, duration, and byte size at debug level, never the response body" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
      end)

      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          assert {:ok, %Summary{}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
        end)

      assert log =~ "status=200"
      assert log =~ "bytes="
      assert log =~ "duration_ms="
      refute log =~ "bataille de Marathon"
    end
  end

  describe "fetch_summary/2 edge cases" do
    test "an en article without a thumbnail decodes with thumbnail_url nil" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_en_no_thumbnail.json"))
      end)

      assert {:ok, %Summary{thumbnail_url: nil, lang: :en}} =
               Rest.fetch_summary(:en, "Third_Council_of_the_Lateran")
    end

    test "a title with parentheses is preserved and re-encoded" do
      Req.Test.stub(Rest, fn conn ->
        assert conn.request_path == "/api/rest_v1/page/summary/Diet_of_Augsburg_%281530%29"
        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_en_no_thumbnail.json"))
      end)

      assert {:ok, %Summary{}} = Rest.fetch_summary(:en, "Diet_of_Augsburg_(1530)")
    end
  end

  describe "fetch_summary/2 error cases" do
    test "HTTP 404 returns {:error, :not_found}" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 404, raw_wikipedia_fixture("not_found.json"))
      end)

      assert {:error, :not_found} = Rest.fetch_summary(:fr, "Article_Inexistant")
    end

    test "malformed (truncated) JSON body returns {:error, {:decode_error, _}}" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("malformed.json"))
      end)

      assert {:error, {:decode_error, %Jason.DecodeError{}}} =
               Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "a well-formed but contract-violating body (missing extract) returns {:error, {:decode_error, _}}" do
      Req.Test.stub(Rest, fn conn ->
        Req.Test.json(conn, %{"title" => "Only a title"})
      end)

      assert {:error, {:decode_error, :invalid_summary_shape}} =
               Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "a contract-violating thumbnail (not a map) is caught at the adapter's exception boundary" do
      Req.Test.stub(Rest, fn conn ->
        Req.Test.json(conn, %{
          "title" => "Titre",
          "extract" => "Extrait",
          "content_urls" => %{"desktop" => %{"page" => "https://fr.wikipedia.org/wiki/Titre"}},
          "thumbnail" => "not-a-map"
        })
      end)

      assert {:error, {:decode_error, _reason}} =
               Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "HTTP 500 returns {:error, {:http_error, 500}}" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal server error")
      end)

      assert {:error, {:http_error, 500}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "receive timeout returns {:error, :timeout}" do
      Req.Test.stub(Rest, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :timeout} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "connection failure returns {:error, {:transport_error, _}}" do
      Req.Test.stub(Rest, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport_error, :econnrefused}} =
               Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end
  end

  describe "fetch_summary/2 rate limiting and backoff (limit cases)" do
    test "429 with Retry-After retries with growing delays then succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(Rest, fn conn ->
        attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        if attempt < 3 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, raw_wikipedia_fixture("rate_limited.json"))
        else
          Plug.Conn.send_resp(conn, 200, raw_wikipedia_fixture("summary_fr.json"))
        end
      end)

      assert {:ok, %Summary{}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
      assert Agent.get(counter, & &1) == 3
    end

    test "429 persisting past the retry budget returns {:error, {:rate_limited, retry_after}}" do
      Req.Test.stub(Rest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.send_resp(429, raw_wikipedia_fixture("rate_limited.json"))
      end)

      assert {:error, {:rate_limited, 7}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "429 without a Retry-After header falls back to exponential backoff and reports nil" do
      Req.Test.stub(Rest, fn conn ->
        Plug.Conn.send_resp(conn, 429, raw_wikipedia_fixture("rate_limited.json"))
      end)

      assert {:error, {:rate_limited, nil}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "429 with a non-numeric Retry-After (e.g. an HTTP-date) is treated as absent" do
      Req.Test.stub(Rest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")
        |> Plug.Conn.send_resp(429, raw_wikipedia_fixture("rate_limited.json"))
      end)

      assert {:error, {:rate_limited, nil}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "429 with a negative Retry-After is ignored (treated as absent)" do
      Req.Test.stub(Rest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "-5")
        |> Plug.Conn.send_resp(429, raw_wikipedia_fixture("rate_limited.json"))
      end)

      assert {:error, {:rate_limited, nil}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "429 with an absurdly large Retry-After is clamped to 300 seconds" do
      Req.Test.stub(Rest, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "86400")
        |> Plug.Conn.send_resp(429, raw_wikipedia_fixture("rate_limited.json"))
      end)

      assert {:error, {:rate_limited, 300}} = Rest.fetch_summary(:fr, "Bataille_de_Marathon")
    end

    test "an extract of unusual length is stored integrally (below the 8192 bound)" do
      long_extract = String.duplicate("a", 5000)

      Req.Test.stub(Rest, fn conn ->
        Req.Test.json(conn, %{
          "title" => "Long article",
          "extract" => long_extract,
          "content_urls" => %{
            "desktop" => %{"page" => "https://fr.wikipedia.org/wiki/Long_article"}
          }
        })
      end)

      assert {:ok, %Summary{extract: extract}} =
               Rest.fetch_summary(:fr, "Long_article")

      assert extract == long_extract
    end
  end
end
