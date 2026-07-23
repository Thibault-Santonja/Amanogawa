defmodule Amanogawa.Ingestion.WikipediaClient.Rest do
  @moduledoc """
  Req-based `Amanogawa.Ingestion.WikipediaClient` adapter for the Wikipedia
  REST API `page/summary` endpoint (see ADR 0003).

  Sends a `GET https://{lang}.wikipedia.org/api/rest_v1/page/summary/{title}`
  request, `title` being the caller's already-decoded title (see
  `Amanogawa.Ingestion.WikipediaClient.title_from_wiki_url/1`) re-encoded
  for the URL path. Redirects are followed (Req's default behaviour):
  Wikipedia issues one when a title differs only by case or is an alias.
  Identifies every request with the Wikimedia-etiquette User-Agent
  (`.claude/rules/ethics.md`):
  `Amanogawa/<version> (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`.

  On HTTP 429 the adapter retries with a bounded exponential backoff,
  honoring the `Retry-After` header when present (clamped into
  `[0, #{inspect(300)}]` seconds; a negative or non-numeric value is
  ignored), up to `#{inspect(3)}` attempts total; beyond that it returns
  `{:error, {:rate_limited, _}}`.

  This module is the only place where transport concerns (HTTP status
  codes, raw response bodies) are visible: every exit path returns either
  `{:ok, Summary.t()}` or one of the tagged errors of
  `Amanogawa.Ingestion.WikipediaClient`. The `try/rescue` guarding the
  response *decoding* path is deliberate and narrow: decoding an untrusted
  body is the one place an out-of-contract document can raise, and this is
  a true system boundary (`.claude/rules/architecture.md`). No other code
  path hides behind a rescue: an unexpected exception elsewhere is a bug
  and must surface as one.
  """

  @behaviour Amanogawa.Ingestion.WikipediaClient

  require Logger

  alias Amanogawa.Ingestion.WikipediaClient.Summary

  @default_connect_timeout :timer.seconds(10)
  @default_receive_timeout :timer.seconds(30)
  @default_backoff_base_ms 500
  @default_retry_after_unit_ms 1000

  # Total attempts on a 429 response, including the first one.
  @max_attempts 3

  @impl true
  @spec fetch_summary(:fr | :en, String.t()) ::
          {:ok, Summary.t()} | {:error, Amanogawa.Ingestion.WikipediaClient.error()}
  def fetch_summary(lang, title) when lang in [:fr, :en] and is_binary(title) do
    attempt_fetch(lang, title, 1)
  end

  defp attempt_fetch(lang, title, attempt_number) do
    started_at = System.monotonic_time(:millisecond)
    response = Req.request(build_request(lang, title))
    log_attempt(response, attempt_number, started_at)

    case response do
      {:ok, %Req.Response{status: 200, body: body}} ->
        decode_body(body, lang)

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: 429} = response} ->
        handle_rate_limited(lang, title, attempt_number, response)

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

  defp handle_rate_limited(lang, title, attempt_number, response) do
    retry_after = retry_after_seconds(response)

    if attempt_number < @max_attempts do
      attempt_number
      |> backoff_delay_ms(retry_after)
      |> sleep()

      attempt_fetch(lang, title, attempt_number + 1)
    else
      {:error, {:rate_limited, retry_after}}
    end
  end

  defp sleep(delay_ms), do: Process.sleep(delay_ms)

  defp backoff_delay_ms(_attempt_number, retry_after_seconds)
       when is_integer(retry_after_seconds) do
    # In production one Retry-After second is one real second; tests scale
    # this down (`retry_after_unit_ms: 1`) so a fixture's `Retry-After: 7`
    # exercises the exact same code path without the suite sleeping 7s.
    retry_after_seconds * config_value(:retry_after_unit_ms, @default_retry_after_unit_ms)
  end

  defp backoff_delay_ms(attempt_number, nil) do
    config_value(:backoff_base_ms, @default_backoff_base_ms) * Integer.pow(2, attempt_number - 1)
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

  # Narrow rescue (see moduledoc): decoding an untrusted body is the one
  # place an out-of-contract document can raise, converted here into the
  # adapter's tagged error.
  defp decode_body(body, lang) do
    case Summary.decode(body, lang) do
      {:ok, summary} -> {:ok, summary}
      {:error, reason} -> {:error, {:decode_error, reason}}
    end
  rescue
    exception ->
      Logger.error(
        "Wikipedia summary response could not be decoded: #{Exception.message(exception)}"
      )

      {:error, {:decode_error, Exception.message(exception)}}
  end

  defp build_request(lang, title) do
    [
      url: "https://#{lang}.wikipedia.org/api/rest_v1/page/summary/#{encode_title(title)}",
      method: :get,
      headers: [
        {"accept", "application/json"},
        {"user-agent", user_agent()}
      ],
      connect_options: [timeout: config_value(:connect_timeout, @default_connect_timeout)],
      receive_timeout: config_value(:receive_timeout, @default_receive_timeout),
      # Retries are driven by this adapter (429 backoff honoring
      # Retry-After), not by Req's generic transient-error retry.
      retry: false,
      # Left disabled for the same reason as the QLever adapter: a
      # malformed body must go through `Summary.decode/2` (and surface as a
      # tagged `:decode_error`), never as a bare `Req.request/1` crash from
      # its own auto-decoding.
      decode_body: false,
      # `nil` (the default: no adapter configuration override) is
      # equivalent to omitting `:plug` entirely, Req then uses its real
      # HTTP transport; tests set it to `{Req.Test, __MODULE__}`.
      plug: config_value(:plug, nil)
    ]
    |> Req.new()
  end

  # Re-encodes the already-decoded title (produced by `Amanogawa.Ingestion.
  # WikipediaClient.title_from_wiki_url/1`) for the URL path: unreserved
  # characters (letters, digits, "-", ".", "_", "~") pass through untouched,
  # keeping the underscore-separated MediaWiki title shape intact; anything
  # else (accents, apostrophes, parentheses) is percent-encoded.
  defp encode_title(title), do: URI.encode(title, &URI.char_unreserved?/1)

  defp config_value(key, default), do: Keyword.get(adapter_config(), key, default)

  defp adapter_config, do: Application.get_env(:amanogawa, __MODULE__, [])

  defp user_agent do
    version = Application.spec(:amanogawa, :vsn) |> to_string()

    "Amanogawa/#{version} (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)"
  end

  # Never log the response body (may embed a long extract): only status,
  # duration, and byte size.
  defp log_attempt({:ok, %Req.Response{status: status, body: body}}, attempt_number, started_at) do
    Logger.debug(fn ->
      "Wikipedia summary attempt=#{attempt_number} status=#{status} " <>
        "duration_ms=#{elapsed_ms(started_at)} bytes=#{byte_size(body)}"
    end)
  end

  defp log_attempt({:error, reason}, attempt_number, started_at) do
    Logger.warning(fn ->
      "Wikipedia summary attempt=#{attempt_number} error=#{inspect(reason)} " <>
        "duration_ms=#{elapsed_ms(started_at)}"
    end)
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
