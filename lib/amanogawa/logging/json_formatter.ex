defmodule Amanogawa.Logging.JSONFormatter do
  @moduledoc """
  Minimal JSON `Logger` formatter for production (issue #028).

  A hand-written formatter, not the `logger_json` dependency: the shape
  needed here (timestamp, level, message, `request_id`, a handful of
  metadata keys) is small enough that a dependency is not justified
  (`.claude/rules/pragmatic-developer.md`, "minimize external libraries").
  Revisit only if this formatter is measurably more expensive to maintain
  than adopting `logger_json`, and document that decision here if it ever
  happens; as of this issue, it has not.

  Wired as `config :logger, :default_formatter, format: {__MODULE__,
  :format}` in production only (`config/runtime.exs`); development keeps
  the human-readable template format unchanged.

  Every log line is a single JSON object on its own line (one line per
  event, easy to `grep`/`jq` through `kamal app logs`, `docs/ops/deploy.md`)
  with these fields:

    * `timestamp` - ISO 8601, UTC, millisecond precision
    * `level` - the Logger level as a string
    * `message` - the log message, coerced to a UTF-8 string
    * `request_id` - present when `Plug.RequestId` set it in the
      metadata (every HTTP request, `AmanogawaWeb.Endpoint`), absent
      otherwise
    * any other metadata key, sanitized (see `sanitize/1`)

  This module is a boundary that receives arbitrary, sometimes hostile
  terms (a crashing process can log almost anything as metadata: pids,
  references, structs, non-UTF-8 binaries, deeply nested terms) and must
  never itself raise or produce invalid JSON; `format/4` is written
  accordingly, mirroring how this codebase treats every other external
  data boundary (`Amanogawa.Ingestion.SparqlClient.Result`, hostile
  fixtures).
  """

  @doc """
  The `Logger` custom formatter callback (`{module, function}` shape).

  Always returns a single line of valid JSON followed by a newline, never
  raises regardless of how pathological `message` or `metadata` are.
  """
  @spec format(Logger.level(), Logger.message(), Logger.Formatter.time(), keyword()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    line =
      %{
        timestamp: format_timestamp(timestamp),
        level: to_string(level),
        message: sanitize_message(message)
      }
      |> put_request_id(metadata)
      |> put_extra_metadata(metadata)
      |> Jason.encode()
      |> case do
        {:ok, json} -> json
        {:error, _reason} -> fallback_line(level, timestamp)
      end

    [line, "\n"]
  rescue
    _exception -> [fallback_line(level, timestamp), "\n"]
  end

  # `Logger.Formatter.time()` is `{date, time}` where `time` carries
  # milliseconds as a fourth element: `{{y, m, d}, {h, mi, s, ms}}`.
  defp format_timestamp({{year, month, day}, {hour, minute, second, millisecond}}) do
    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second, millisecond * 1000)

    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp put_request_id(entry, metadata) do
    case Keyword.get(metadata, :request_id) do
      nil -> entry
      request_id -> Map.put(entry, :request_id, sanitize(request_id))
    end
  end

  @reserved_keys [:request_id]

  defp put_extra_metadata(entry, metadata) do
    extra =
      metadata
      |> Keyword.drop(@reserved_keys)
      |> Map.new(fn {key, value} -> {key, sanitize(value)} end)

    if map_size(extra) == 0, do: entry, else: Map.put(entry, :metadata, extra)
  end

  defp sanitize_message(message) do
    message
    |> IO.chardata_to_string()
    |> sanitize_string()
  rescue
    # `IO.chardata_to_string/1` raises on chardata containing invalid
    # code points or non-UTF-8 binaries (issue #028's "binaire non UTF-8"
    # error case): fall back to `inspect/1`, which always succeeds.
    _exception -> inspect(message)
  end

  # Recursively rebuilds `term` into something `Jason.encode/1` can always
  # handle: plain maps/lists/numbers/booleans/nil pass through (with
  # string-keyed maps, since JSON object keys are strings), everything
  # else (pid, reference, port, function, tuple, struct, atom, non-UTF-8
  # binary) becomes its `inspect/1` text. Depth-bounded so a maliciously
  # or accidentally deeply nested term cannot blow the stack (mirrors the
  # ingestion pipeline's own hostile-input posture).
  @max_depth 6

  defp sanitize(term), do: sanitize(term, @max_depth)

  # Only containers are truncated at depth 0: a scalar (string, number,
  # atom, ...) sitting exactly at the bound must still render normally,
  # never turn into the truncation marker just because nothing was left
  # to recurse into.
  defp sanitize(term, 0) when (is_map(term) and not is_struct(term)) or is_list(term), do: "…"

  defp sanitize(term, depth) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {sanitize_key(key), sanitize(value, depth - 1)} end)
  end

  defp sanitize(term, depth) when is_list(term) do
    if Keyword.keyword?(term) do
      Map.new(term, fn {key, value} -> {sanitize_key(key), sanitize(value, depth - 1)} end)
    else
      Enum.map(term, &sanitize(&1, depth - 1))
    end
  rescue
    # A charlist is a list of integers: `Keyword.keyword?/1` above is safe
    # on it, but a list mixing non-atom keys can still reach code paths
    # that raise; inspect it instead of ever letting that surface.
    _exception -> inspect(term)
  end

  defp sanitize(term, _depth) when is_binary(term), do: sanitize_string(term)
  defp sanitize(term, _depth) when is_number(term) or is_boolean(term) or is_nil(term), do: term
  defp sanitize(term, _depth) when is_atom(term), do: Atom.to_string(term)
  defp sanitize(term, _depth), do: inspect(term)

  defp sanitize_key(key) when is_binary(key), do: sanitize_string(key)
  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key), do: inspect(key)

  defp sanitize_string(string) do
    if String.valid?(string), do: string, else: inspect(string)
  end

  # Only ever fed plain strings built from `to_string/1` on an atom and
  # `format_timestamp_safe/1`'s own fallback: `Jason.encode!/1` cannot
  # fail on that input, so this is the line that is truly always valid
  # JSON, however hostile `message`/`metadata` turned out to be.
  defp fallback_line(level, timestamp) do
    Jason.encode!(%{
      timestamp: format_timestamp_safe(timestamp),
      level: to_string(level),
      message: "(unserializable log entry)"
    })
  end

  defp format_timestamp_safe(timestamp) do
    format_timestamp(timestamp)
  rescue
    _exception -> "unknown"
  end
end
