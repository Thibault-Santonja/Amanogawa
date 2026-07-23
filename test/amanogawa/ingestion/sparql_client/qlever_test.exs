defmodule Amanogawa.Ingestion.SparqlClient.QLeverTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Amanogawa.SparqlFixtures

  alias Amanogawa.Ingestion.SparqlClient.QLever
  alias Amanogawa.Ingestion.SparqlClient.Result

  describe "query/2 happy path" do
    test "decodes the nominal fixture into a Result, preserving datatype and lang" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, Jason.decode!(raw_sparql_fixture("nominal.json")))
      end)

      assert {:ok, %Result{variables: variables, bindings: bindings}} =
               QLever.query("SELECT ?event WHERE { ?event ?p ?o }", [])

      assert variables == ["event", "eventLabel", "date", "datePrecision", "coord", "articleFr"]
      assert length(bindings) == 4

      marathon =
        Enum.find(bindings, &(&1["event"].value == "http://www.wikidata.org/entity/Q31900"))

      assert marathon["date"].value == "-0489-09-05T00:00:00Z"
      assert marathon["date"].datatype == "http://www.w3.org/2001/XMLSchema#dateTime"
      assert marathon["eventLabel"].lang == "fr"
      assert marathon["coord"].type == :literal
    end

    test "sends the identified User-Agent and Accept/Content-Type headers" do
      Req.Test.stub(QLever, fn conn ->
        assert [user_agent] = Plug.Conn.get_req_header(conn, "user-agent")

        assert user_agent =~
                 ~r"^Amanogawa/[\d.]+ \(https://github\.com/Thibault-Santonja/Amanogawa; thibault\.santonja@gmail\.com\)$"

        assert Plug.Conn.get_req_header(conn, "accept") == ["application/sparql-results+json"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/sparql-query"]

        Req.Test.json(conn, %{"head" => %{"vars" => []}, "results" => %{"bindings" => []}})
      end)

      assert {:ok, %Result{}} = QLever.query("ASK { ?s ?p ?o }", [])
    end

    test "sends the SPARQL query as the raw POST body" do
      sparql = "SELECT ?event WHERE { ?event ?p ?o }"

      Req.Test.stub(QLever, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert body == sparql

        Req.Test.json(conn, %{"head" => %{"vars" => []}, "results" => %{"bindings" => []}})
      end)

      assert {:ok, %Result{}} = QLever.query(sparql, [])
    end

    test "a per-call opt overrides the configured base URL" do
      Req.Test.stub(QLever, fn conn ->
        assert conn.request_path == "/api/wikidata-custom"

        Req.Test.json(conn, %{"head" => %{"vars" => []}, "results" => %{"bindings" => []}})
      end)

      assert {:ok, %Result{}} =
               QLever.query("ASK {}", base_url: "https://qlever.dev/api/wikidata-custom")
    end

    test "logs status, duration, and byte size at debug level, never the response body" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, %{"head" => %{"vars" => []}, "results" => %{"bindings" => []}})
      end)

      # The suite runs at :warning (config/test.exs), a global primary
      # level that a per-process override cannot bypass: raise it for the
      # duration of this test only, so the debug log actually fires.
      previous_level = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous_level) end)

      log =
        capture_log(fn ->
          assert {:ok, %Result{}} = QLever.query("ASK {}", [])
        end)

      assert log =~ "status=200"
      assert log =~ "bytes="
      assert log =~ "duration_ms="
      refute log =~ "results"
    end
  end

  describe "query/2 edge cases" do
    test "empty result: zero bindings" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, Jason.decode!(raw_sparql_fixture("empty.json")))
      end)

      assert {:ok, %Result{bindings: []}} = QLever.query("ASK { ?s ?p ?o }", [])
    end

    test "binding without datatype or lang decodes with nil fields" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, %{
          "head" => %{"vars" => ["s"]},
          "results" => %{
            "bindings" => [%{"s" => %{"type" => "uri", "value" => "http://example.org/s"}}]
          }
        })
      end)

      assert {:ok, %Result{bindings: [%{"s" => value}]}} = QLever.query("ASK {}", [])
      assert value == %{value: "http://example.org/s", type: :uri, datatype: nil, lang: nil}
    end

    test "non-ASCII literal values are preserved" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, %{
          "head" => %{"vars" => ["label"]},
          "results" => %{
            "bindings" => [
              %{"label" => %{"type" => "literal", "value" => "天の川", "xml:lang" => "ja"}}
            ]
          }
        })
      end)

      assert {:ok, %Result{bindings: [%{"label" => value}]}} = QLever.query("ASK {}", [])
      assert value.value == "天の川"
    end
  end

  describe "query/2 error cases" do
    test "HTTP 500 returns {:error, {:http_error, 500}}" do
      Req.Test.stub(QLever, fn conn ->
        Plug.Conn.send_resp(conn, 500, "internal server error")
      end)

      assert {:error, {:http_error, 500}} = QLever.query("ASK {}", [])
    end

    test "an HTML error page (out-of-contract response) returns {:error, {:decode_error, _}}" do
      Req.Test.stub(QLever, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, raw_sparql_fixture("error.html"))
      end)

      assert {:error, {:decode_error, _reason}} = QLever.query("ASK {}", [])
    end

    test "malformed (truncated) JSON body returns {:error, {:decode_error, _}}" do
      Req.Test.stub(QLever, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/sparql-results+json")
        |> Plug.Conn.send_resp(200, raw_sparql_fixture("malformed.json"))
      end)

      assert {:error, {:decode_error, %Jason.DecodeError{}}} = QLever.query("ASK {}", [])
    end

    test "a well-formed but contract-violating binding (missing type/value) never crashes the caller" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.json(conn, %{
          "head" => %{"vars" => ["s"]},
          "results" => %{"bindings" => [%{"s" => %{"value" => "missing-type"}}]}
        })
      end)

      assert {:error, {:decode_error, _reason}} = QLever.query("ASK {}", [])
    end

    test "receive timeout returns {:error, :timeout}" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :timeout} = QLever.query("ASK {}", [])
    end

    test "connection failure returns {:error, {:transport_error, _}}" do
      Req.Test.stub(QLever, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:transport_error, :econnrefused}} = QLever.query("ASK {}", [])
    end
  end

  describe "query/2 rate limiting and backoff" do
    test "429 with Retry-After retries with growing delays then succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(QLever, fn conn ->
        attempt = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

        if attempt < 3 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, "")
        else
          Req.Test.json(conn, %{"head" => %{"vars" => []}, "results" => %{"bindings" => []}})
        end
      end)

      assert {:ok, %Result{}} = QLever.query("ASK {}", [])
      assert Agent.get(counter, & &1) == 3
    end

    test "429 persisting past the retry budget returns {:error, {:rate_limited, retry_after}}" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(QLever, fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, {:rate_limited, 7}} = QLever.query("ASK {}", [])
      # Total attempts bounded at 3: the adapter does not retry forever.
      assert Agent.get(counter, & &1) == 3
    end

    test "429 without a Retry-After header falls back to exponential backoff and reports nil" do
      Req.Test.stub(QLever, fn conn ->
        Plug.Conn.send_resp(conn, 429, "")
      end)

      assert {:error, {:rate_limited, nil}} = QLever.query("ASK {}", [])
    end

    test "429 with a non-numeric Retry-After (e.g. an HTTP-date) is treated as absent" do
      Req.Test.stub(QLever, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, {:rate_limited, nil}} = QLever.query("ASK {}", [])
    end
  end

  describe "query/2 volume" do
    test "a large response (thousands of bindings) decodes without degradation" do
      Req.Test.stub(QLever, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/sparql-results+json")
        |> Plug.Conn.send_resp(200, raw_sparql_fixture("large.json"))
      end)

      assert {:ok, %Result{bindings: bindings}} = QLever.query("ASK {}", [])
      assert length(bindings) == 3000
      assert Enum.all?(bindings, &Map.has_key?(&1, "event"))
    end
  end
end
