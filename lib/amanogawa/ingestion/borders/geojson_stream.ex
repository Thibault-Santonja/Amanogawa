defmodule Amanogawa.Ingestion.Borders.GeojsonStream do
  @moduledoc """
  Reads a GeoJSON `FeatureCollection` file's top-level `"features"` array
  one feature at a time, in constant memory, regardless of file size
  (issue #023: Cliopatria's export is ~307MB; loading it whole is
  forbidden).

  ## Why a hand-rolled scanner rather than a streaming JSON library

  The only actively maintained event-based JSON parser in the Elixir
  ecosystem at evaluation time (`jaxon`) has had no release since 2021
  (`.claude/rules/elixir-idioms.md`: "Adding a dependency requires
  checking: maintained"); every other candidate found on hex.pm either
  decodes the whole document at once (`jsonrs`, `thoas`) or only streams
  encoding, not decoding (`json_stream_encoder`). The shape this module
  needs to support is fixed and narrow (a `FeatureCollection`'s `features`
  array, reused as-is by both #023 and #024's sources), so a small,
  self-contained scanner over `Jason` (already a dependency, used only to
  decode one already-isolated feature object at a time, never the whole
  file) is more maintainable than depending on an abandoned library for a
  feature this module does not otherwise need.

  ## How it works

  Three phases, driven by `Stream.transform/3` over `File.stream!/3`
  fixed-size byte chunks, so memory never holds more than one chunk plus
  one in-progress feature's text:

    1. **Seek**: accumulate bytes (capped at `@seek_limit_bytes`, a
       generous bound for a header far smaller than that) until the literal
       key `"features"` is found, then the next `[`. Raises if the array
       start is not found within the cap: a file without a `"features"`
       array is not a `FeatureCollection` this module can read, and it is
       better to fail loudly and immediately than to silently scan the
       whole file for nothing.
    2. **Between**: skip whitespace/commas between features; `{` starts
       one, `]` ends the array (everything after is ignored: this module
       only ever needs the features array itself).
    3. **In feature**: a brace-depth counter, aware of JSON string/escape
       context (so a `{` or `}` inside a string value, or an escaped quote,
       never miscounts), accumulates the feature's exact text until its
       matching closing brace, then hands the substring to `Jason.decode/1`.

  Yields `{:ok, feature_map}` for each syntactically valid feature, or
  `{:error, {:invalid_json, reason}}` for one that is not (a single
  malformed feature never stops the stream, `.claude/rules/testing.md`'s
  "error case" for this pipeline; domain-level validation, e.g. a missing
  `Name` property, is the caller's concern, see
  `Amanogawa.Ingestion.Cliopatria.Parser`).

      iex> path = Path.join(System.tmp_dir!(), "geojson_stream_doctest.json")
      iex> File.write!(path, ~s({"type":"FeatureCollection","features":[{"type":"Feature","properties":{"a":1}},{"type":"Feature","properties":{"b":2}}]}))
      iex> Amanogawa.Ingestion.Borders.GeojsonStream.features(path) |> Enum.to_list()
      [ok: %{"type" => "Feature", "properties" => %{"a" => 1}}, ok: %{"type" => "Feature", "properties" => %{"b" => 2}}]

  """

  @seek_limit_bytes 1_048_576
  @default_chunk_bytes 65_536

  @type feature :: {:ok, map()} | {:error, {:invalid_json, term()}}

  @doc """
  Returns a lazy `Stream` of `t:feature/0` read from the `"features"` array
  of the `FeatureCollection` at `path`.

  `opts`:

    * `:chunk_bytes` - bytes read per underlying `File.stream!/3` chunk,
      default #{@default_chunk_bytes}. Exposed mainly so tests can force
      many small chunks against a tiny fixture and exercise every state
      transition across a chunk boundary; production callers never need to
      override it.
  """
  # `path` is a local filesystem path an operator passes to a mix task
  # (`mix amanogawa.import.cliopatria`/`mix amanogawa.import.
  # historical_basemaps`), never web/user-controlled input: there is no
  # remote request path that reaches this function. Sobelow's directory
  # traversal check cannot distinguish that from a web-facing case, hence
  # this explicit, scoped skip rather than suppressing the whole scan.
  # sobelow_skip ["Traversal.FileModule"]
  @spec features(Path.t(), keyword()) :: Enumerable.t(feature())
  def features(path, opts \\ []) do
    chunk_bytes = Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)

    # `last_fun` (arity 5), not `after_fun` (arity 4): `last_fun` only runs
    # when the underlying `File.Stream` itself finishes successfully, so a
    # genuine `File.Error` (missing file, permissions) propagates as-is.
    # `after_fun` runs unconditionally, including after an upstream error,
    # in the same `try/after` sense as Erlang: `finalize/2` raising there
    # (a truncated file: the scanner never reached `:done`) would silently
    # replace that original `File.Error` with a confusing "truncated file"
    # message instead.
    path
    |> File.stream!([], chunk_bytes)
    |> Stream.transform(&initial_state/0, &scan/2, &finalize(&1, path), fn _state -> :ok end)
  end

  defp initial_state do
    %{mode: :seek, seek_buffer: <<>>, depth: 0, in_string: false, escaped: false, buffer: []}
  end

  defp scan(chunk, state) do
    {emitted, new_state} = consume(chunk, state, [])
    {Enum.reverse(emitted), new_state}
  end

  defp consume(<<>>, state, emitted), do: {emitted, state}

  defp consume(bin, %{mode: :seek} = state, emitted) do
    seek_buffer = state.seek_buffer <> bin

    case find_array_start(seek_buffer) do
      {:ok, rest} ->
        consume(rest, %{state | mode: :between, seek_buffer: <<>>}, emitted)

      :not_found ->
        if byte_size(seek_buffer) > @seek_limit_bytes do
          raise "GeojsonStream: no top-level \"features\" array found within the first " <>
                  "#{@seek_limit_bytes} bytes"
        end

        {emitted, %{state | seek_buffer: seek_buffer}}
    end
  end

  defp consume(<<c, rest::binary>>, %{mode: :between} = state, emitted)
       when c in [?\s, ?\n, ?\r, ?\t, ?,] do
    consume(rest, state, emitted)
  end

  defp consume(<<?{, rest::binary>>, %{mode: :between} = state, emitted) do
    feature_state = %{state | mode: :in_feature, depth: 1, in_string: false, buffer: [<<?{>>]}
    consume(rest, feature_state, emitted)
  end

  defp consume(<<?], _rest::binary>>, %{mode: :between} = state, emitted) do
    {emitted, %{state | mode: :done}}
  end

  defp consume(<<byte, rest::binary>>, %{mode: :in_feature, in_string: true} = state, emitted) do
    cond do
      state.escaped ->
        consume(rest, %{state | escaped: false, buffer: [<<byte>> | state.buffer]}, emitted)

      byte == ?\\ ->
        consume(rest, %{state | escaped: true, buffer: [<<byte>> | state.buffer]}, emitted)

      byte == ?" ->
        consume(rest, %{state | in_string: false, buffer: [<<byte>> | state.buffer]}, emitted)

      true ->
        consume(rest, %{state | buffer: [<<byte>> | state.buffer]}, emitted)
    end
  end

  defp consume(<<?", rest::binary>>, %{mode: :in_feature} = state, emitted) do
    consume(rest, %{state | in_string: true, buffer: [<<?">> | state.buffer]}, emitted)
  end

  defp consume(<<?{, rest::binary>>, %{mode: :in_feature} = state, emitted) do
    consume(rest, %{state | depth: state.depth + 1, buffer: [<<?{>> | state.buffer]}, emitted)
  end

  defp consume(<<?}, rest::binary>>, %{mode: :in_feature, depth: 1} = state, emitted) do
    feature_json = [<<?}>> | state.buffer] |> Enum.reverse() |> IO.iodata_to_binary()
    decoded = decode_feature(feature_json)
    new_state = %{state | mode: :between, depth: 0, buffer: []}
    consume(rest, new_state, [decoded | emitted])
  end

  defp consume(<<?}, rest::binary>>, %{mode: :in_feature} = state, emitted) do
    consume(rest, %{state | depth: state.depth - 1, buffer: [<<?}>> | state.buffer]}, emitted)
  end

  defp consume(<<byte, rest::binary>>, %{mode: :in_feature} = state, emitted) do
    consume(rest, %{state | buffer: [<<byte>> | state.buffer]}, emitted)
  end

  # The array closed (`]` consumed above): everything after it (other
  # top-level FeatureCollection keys, the closing `}`) is deliberately
  # ignored, chunk after chunk, until the file ends.
  defp consume(_bin, %{mode: :done} = state, emitted), do: {emitted, state}

  defp decode_feature(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # Finds the first `[` following the literal key `"features"` (whitespace
  # and a `:` tolerated in between, matching every real-world GeoJSON
  # formatting seen from both Cliopatria and historical-basemaps: minified
  # or pretty-printed). Returns the bytes strictly after that `[` so the
  # caller resumes scanning from the first feature (or `]` for an empty
  # collection).
  defp find_array_start(buffer) do
    case :binary.match(buffer, "\"features\"") do
      {pos, len} ->
        after_key = binary_part(buffer, pos + len, byte_size(buffer) - pos - len)
        skip_to_bracket(after_key)

      :nomatch ->
        :not_found
    end
  end

  defp skip_to_bracket(<<c, rest::binary>>) when c in [?\s, ?\n, ?\r, ?\t, ?:] do
    skip_to_bracket(rest)
  end

  defp skip_to_bracket(<<?[, rest::binary>>), do: {:ok, rest}
  defp skip_to_bracket(<<>>), do: :not_found

  defp skip_to_bracket(_other) do
    raise ~s|GeojsonStream: expected "features" to be followed by an array ("[")|
  end

  defp finalize(%{mode: :done} = state, _path), do: {[], state}

  defp finalize(%{mode: :seek}, path) do
    raise "GeojsonStream: no top-level \"features\" array found in #{inspect(path)}"
  end

  defp finalize(%{mode: mode}, path) do
    raise "GeojsonStream: #{inspect(path)} ended while still in #{inspect(mode)} state " <>
            "(truncated file or an unterminated \"features\" array)"
  end
end
