defmodule Amanogawa.Ingestion.SparqlClient.QLever do
  @moduledoc """
  Req-based `Amanogawa.Ingestion.SparqlClient` adapter for the QLever
  SPARQL endpoint (see ADR 0003).

  Sends a `POST` request with an `application/sparql-query` body, requests
  `application/sparql-results+json` back, and identifies every request with
  the Wikimedia-etiquette User-Agent (`.claude/rules/ethics.md`):
  `Amanogawa/<version> (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`.

  On HTTP 429 the adapter retries with a bounded exponential backoff,
  honoring the `Retry-After` header when present (clamped into
  `[0, #{inspect(300)}]` seconds; a negative or non-numeric value is
  ignored), up to `#{inspect(3)}` attempts total; beyond that it returns
  `{:error, {:rate_limited, _}}`.

  This module is the only place where transport concerns (HTTP status
  codes, raw response bodies) are visible: every exit path returns either
  `{:ok, Result.t()}` or one of the tagged errors of
  `Amanogawa.Ingestion.SparqlClient`. The `try/rescue` guarding the
  response *decoding* path is deliberate and narrow: decoding an untrusted
  body is the one place an out-of-contract document can raise
  (`Result.decode/1`'s documented behavior for malformed bindings), and
  this is a true system boundary (`.claude/rules/architecture.md`). No
  other code path hides behind a rescue: an unexpected exception elsewhere
  is a bug and must surface as one.
  """

  @behaviour Amanogawa.Ingestion.SparqlClient

  require Logger

  alias Amanogawa.Ingestion.SparqlClient.Result

  @default_base_url "https://qlever.dev/api/wikidata"
  @default_connect_timeout :timer.seconds(15)
  @default_receive_timeout :timer.seconds(120)
  @default_backoff_base_ms 500
  @default_retry_after_unit_ms 1000

  # Total attempts on a 429 response, including the first one.
  @max_attempts 3

  @impl true
  @spec query(String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, Amanogawa.Ingestion.SparqlClient.error()}
  def query(sparql, opts \\ []) when is_binary(sparql) do
    attempt_query(sparql, opts, 1)
  end

  defp attempt_query(sparql, opts, attempt_number) do
    started_at = System.monotonic_time(:millisecond)
    response = Req.request(build_request(sparql, opts))
    log_attempt(response, attempt_number, started_at)

    case response do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_body(body)

      {:ok, %Req.Response{status: 429} = response} ->
        handle_rate_limited(sparql, opts, attempt_number, response)

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, :timeout}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport_error, reason}}

      # Exhaustiveness net: every failure Req's real HTTP transport can
      # raise is a `Req.TransportError` (connection refused, timeout,
      # TLS...); this catches anything else Req might ever return here
      # without leaking an unmatched-case crash across the adapter
      # boundary.
      {:error, exception} ->
        {:error, {:transport_error, Exception.message(exception)}}
    end
  end

  defp handle_rate_limited(sparql, opts, attempt_number, response) do
    retry_after = retry_after_seconds(response)

    if attempt_number < @max_attempts do
      attempt_number
      |> backoff_delay_ms(retry_after, opts)
      |> sleep()

      attempt_query(sparql, opts, attempt_number + 1)
    else
      {:error, {:rate_limited, retry_after}}
    end
  end

  defp sleep(delay_ms), do: Process.sleep(delay_ms)

  defp backoff_delay_ms(_attempt_number, retry_after_seconds, opts)
       when is_integer(retry_after_seconds) do
    # In production one Retry-After second is one real second; tests scale
    # this down (`retry_after_unit_ms: 1`) so a fixture's `Retry-After: 7`
    # exercises the exact same code path without the suite sleeping 7s.
    unit_ms = config_value(opts, :retry_after_unit_ms, @default_retry_after_unit_ms)
    retry_after_seconds * unit_ms
  end

  defp backoff_delay_ms(attempt_number, nil, opts) do
    base_ms = config_value(opts, :backoff_base_ms, @default_backoff_base_ms)
    base_ms * Integer.pow(2, attempt_number - 1)
  end

  defp retry_after_seconds(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] -> parse_retry_after(value)
      [] -> nil
    end
  end

  # A negative or non-numeric Retry-After is ignored (nil: fall back to the
  # exponential backoff); an absurdly large one is clamped to 300 seconds so
  # a hostile or misconfigured endpoint cannot park the pipeline for hours.
  defp parse_retry_after(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> min(seconds, 300)
      _ -> nil
    end
  end

  # Narrow rescue (see moduledoc): `Result.decode/1` raises on documents
  # that violate the SPARQL results format contract, and this is where that
  # raise is converted into the adapter's tagged error.
  defp decode_body(body) do
    case Result.decode(body) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  rescue
    exception ->
      Logger.error("SPARQL response could not be decoded: #{Exception.message(exception)}")
      {:error, {:decode_error, Exception.message(exception)}}
  end

  defp build_request(sparql, opts) do
    [
      url: config_value(opts, :base_url, @default_base_url),
      method: :post,
      body: sparql,
      headers: [
        {"content-type", "application/sparql-query"},
        {"accept", "application/sparql-results+json"},
        {"user-agent", user_agent()}
      ],
      connect_options: [timeout: config_value(opts, :connect_timeout, @default_connect_timeout)],
      receive_timeout: config_value(opts, :receive_timeout, @default_receive_timeout),
      # Retries are driven by this adapter (429 backoff honoring
      # Retry-After), not by Req's generic transient-error retry.
      retry: false,
      # `application/sparql-results+json` matches Req's built-in "+json"
      # suffix auto-decode: left enabled, a malformed body would surface as
      # a bare `{:error, %Jason.DecodeError{}}` from `Req.request/1` itself
      # (indistinguishable from a transport failure) instead of going
      # through `Result.decode/1`. Decoding is this adapter's job alone.
      decode_body: false,
      # `nil` (the default: no adapter configuration override) is
      # equivalent to omitting `:plug` entirely, Req then uses its real
      # HTTP transport; tests set it to `{Req.Test, __MODULE__}`.
      plug: config_value(opts, :plug, nil)
    ]
    |> Req.new()
  end

  defp config_value(opts, key, default) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> Keyword.get(adapter_config(), key, default)
    end
  end

  defp adapter_config, do: Application.get_env(:amanogawa, __MODULE__, [])

  defp user_agent do
    version = Application.spec(:amanogawa, :vsn) |> to_string()

    "Amanogawa/#{version} (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)"
  end

  # Never log the request or response body (potentially large SPARQL
  # queries and result sets): only status, duration, and byte size. `body`
  # is always a raw binary here: `decode_body: false` (see `build_request/2`)
  # guarantees Req never turns it into a decoded term first.
  defp log_attempt({:ok, %Req.Response{status: status, body: body}}, attempt_number, started_at) do
    Logger.debug(fn ->
      "QLever query attempt=#{attempt_number} status=#{status} " <>
        "duration_ms=#{elapsed_ms(started_at)} bytes=#{byte_size(body)}"
    end)
  end

  defp log_attempt({:error, reason}, attempt_number, started_at) do
    Logger.warning(fn ->
      "QLever query attempt=#{attempt_number} error=#{inspect(reason)} " <>
        "duration_ms=#{elapsed_ms(started_at)}"
    end)
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
