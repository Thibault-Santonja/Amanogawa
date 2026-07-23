defmodule Amanogawa.Ingestion.Borders.GeojsonStream do
  @moduledoc """
  Reads a GeoJSON `FeatureCollection` file's top-level `"features"` array
  one feature at a time, with memory bounded per feature (one chunk plus
  the in-progress feature's text, itself capped at
  `#{32 * 1024 * 1024}` bytes), regardless of file size (issue #023:
  Cliopatria's export is ~307MB; loading it whole is forbidden).

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
  fixed-size byte chunks:

    1. **Seek**: accumulate bytes (capped at `@seek_limit_bytes`, a
       generous bound for a header far smaller than that) until the
       `"features"` key is found at the top level of the root object,
       then the `[` that opens its array. The seek scanner is JSON-aware:
       it tracks string and escape context plus brace/bracket depth, so a
       header string *value* containing `"features"` (a title, a
       description) never triggers a false match; only a depth-1 key
       named `features` followed by `:` and `[` does. Raises if the array
       start is not found within the cap: a file without a `"features"`
       array is not a `FeatureCollection` this module can read, and it is
       better to fail loudly and immediately than to silently scan the
       whole file for nothing.
    2. **Between**: skip whitespace/commas between features; `{` starts
       one, `]` ends the array (everything after is ignored: this module
       only ever needs the features array itself). Any other byte starts
       a non-object array element (`null`, a number, a string): it is
       consumed up to the next top-level `,` or `]` and emitted as
       `{:error, {:invalid_json, :non_object_feature}}`, counted by the
       caller, never fatal.
    3. **In feature**: a brace-depth counter, aware of JSON string/escape
       context (so a `{` or `}` inside a string value, or an escaped quote,
       never miscounts), accumulates the feature's exact text until its
       matching closing brace, then hands the substring to `Jason.decode/1`.
       Accumulation is by contiguous chunk slices (`binary_part/3` at
       chunk transitions and at the feature's end), never one binary per
       byte: a per-byte accumulator was measured at roughly 50x memory
       amplification over the feature's own size. A feature whose text
       exceeds `:max_feature_bytes` (default #{32 * 1024 * 1024} bytes)
       is discarded while the scanner keeps tracking its braces to
       resynchronize on the matching closing brace, then emitted as
       `{:error, {:invalid_json, :feature_too_large}}`: rejected and
       counted, never a raise.

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
  @default_max_feature_bytes 32 * 1024 * 1024

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
    * `:max_feature_bytes` - per-feature text size cap, default
      #{@default_max_feature_bytes}. A feature larger than this is
      rejected (`{:error, {:invalid_json, :feature_too_large}}`) and the
      scanner resynchronizes on its closing brace. Exposed so tests can
      exercise the cap without a multi-gigabyte fixture.
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
    max_feature_bytes = Keyword.get(opts, :max_feature_bytes, @default_max_feature_bytes)

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
    |> Stream.transform(
      fn -> initial_state(max_feature_bytes) end,
      &scan/2,
      &finalize(&1, path),
      fn _state -> :ok end
    )
  end

  defp initial_state(max_feature_bytes) do
    %{
      mode: :seek,
      seek_buffer: <<>>,
      depth: 0,
      in_string: false,
      escaped: false,
      # Reversed list of contiguous binary slices of the in-progress
      # feature's text, closed at chunk transitions and at the feature's
      # end: never one binary per byte (see the moduledoc).
      buffer: [],
      feature_bytes: 0,
      max_feature_bytes: max_feature_bytes
    }
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

  defp consume(<<?{, _rest::binary>> = bin, %{mode: :between} = state, emitted) do
    feature_state = %{
      state
      | mode: :in_feature,
        depth: 1,
        in_string: false,
        escaped: false,
        buffer: [],
        feature_bytes: 0
    }

    # The opening brace is part of the feature's text: scanning restarts
    # at offset 1 with the slice opened at offset 0, so the brace lands in
    # the same contiguous slice as the bytes that follow it.
    scan_feature(bin, 1, 0, feature_state, emitted)
  end

  defp consume(<<?], _rest::binary>>, %{mode: :between} = state, emitted) do
    {emitted, %{state | mode: :done}}
  end

  # Non-object array element (`null`, a number, a bare string, `[...]`):
  # tolerated as one rejected element rather than a fatal error. Consumed
  # up to the next top-level `,` or `]`, then emitted as a tagged error.
  defp consume(bin, %{mode: :between} = state, emitted) do
    consume_junk(bin, %{state | mode: :junk, in_string: false, escaped: false}, emitted)
  end

  defp consume(bin, %{mode: :junk} = state, emitted), do: consume_junk(bin, state, emitted)

  defp consume(bin, %{mode: mode} = state, emitted) when mode in [:in_feature, :skip_feature] do
    scan_feature(bin, 0, 0, state, emitted)
  end

  # The array closed (`]` consumed above): everything after it (other
  # top-level FeatureCollection keys, the closing `}`) is deliberately
  # ignored, chunk after chunk, until the file ends.
  defp consume(_bin, %{mode: :done} = state, emitted), do: {emitted, state}

  # Byte-scanner for one feature object: `offset` walks the chunk,
  # `slice_start` marks where the current contiguous slice began. The
  # slice is closed (one `binary_part/3`) when the feature ends or the
  # chunk runs out, never per byte.
  defp scan_feature(bin, offset, slice_start, state, emitted) when offset < byte_size(bin) do
    byte = :binary.at(bin, offset)

    if state.in_string do
      scan_feature(bin, offset + 1, slice_start, string_step(state, byte), emitted)
    else
      scan_feature_step(byte, bin, offset, slice_start, state, emitted)
    end
  end

  # Chunk exhausted mid-feature: close the current slice and wait for the
  # next chunk. An oversized feature flips to `:skip_feature` here (and in
  # `finish_feature/5` below): its text is discarded but the brace/string
  # tracking continues, so the scanner resynchronizes on the feature's own
  # closing brace instead of raising.
  defp scan_feature(bin, offset, slice_start, state, emitted) do
    slice_len = offset - slice_start
    state = accumulate_slice(bin, slice_start, slice_len, state)
    {emitted, state}
  end

  # One out-of-string byte of the in-progress feature.
  defp scan_feature_step(?", bin, offset, slice_start, state, emitted) do
    scan_feature(bin, offset + 1, slice_start, %{state | in_string: true}, emitted)
  end

  defp scan_feature_step(?{, bin, offset, slice_start, state, emitted) do
    scan_feature(bin, offset + 1, slice_start, %{state | depth: state.depth + 1}, emitted)
  end

  defp scan_feature_step(?}, bin, offset, slice_start, %{depth: 1} = state, emitted) do
    finish_feature(bin, offset, slice_start, state, emitted)
  end

  defp scan_feature_step(?}, bin, offset, slice_start, state, emitted) do
    scan_feature(bin, offset + 1, slice_start, %{state | depth: state.depth - 1}, emitted)
  end

  defp scan_feature_step(_byte, bin, offset, slice_start, state, emitted) do
    scan_feature(bin, offset + 1, slice_start, state, emitted)
  end

  # One byte inside a JSON string, shared by every scanner of this module:
  # tracks escape sequences and the closing quote, leaving all other state
  # untouched.
  defp string_step(%{escaped: true} = state, _byte), do: %{state | escaped: false}
  defp string_step(state, ?\\), do: %{state | escaped: true}
  defp string_step(state, ?"), do: %{state | in_string: false}
  defp string_step(state, _byte), do: state

  defp finish_feature(bin, offset, slice_start, %{mode: :in_feature} = state, emitted) do
    state = accumulate_slice(bin, slice_start, offset - slice_start + 1, state)
    rest = binary_part(bin, offset + 1, byte_size(bin) - offset - 1)

    decoded =
      case state.mode do
        # `accumulate_slice/4` tripped the size cap on this final slice.
        :skip_feature ->
          {:error, {:invalid_json, :feature_too_large}}

        :in_feature ->
          state.buffer |> Enum.reverse() |> IO.iodata_to_binary() |> decode_feature()
      end

    new_state = %{state | mode: :between, depth: 0, buffer: [], feature_bytes: 0}
    consume(rest, new_state, [decoded | emitted])
  end

  defp finish_feature(bin, offset, _slice_start, %{mode: :skip_feature} = state, emitted) do
    rest = binary_part(bin, offset + 1, byte_size(bin) - offset - 1)
    decoded = {:error, {:invalid_json, :feature_too_large}}
    new_state = %{state | mode: :between, depth: 0, buffer: [], feature_bytes: 0}
    consume(rest, new_state, [decoded | emitted])
  end

  defp accumulate_slice(_bin, _slice_start, 0, state), do: state

  defp accumulate_slice(_bin, _slice_start, slice_len, %{mode: :skip_feature} = state) do
    %{state | feature_bytes: state.feature_bytes + slice_len}
  end

  defp accumulate_slice(bin, slice_start, slice_len, state) do
    feature_bytes = state.feature_bytes + slice_len

    if feature_bytes > state.max_feature_bytes do
      %{state | mode: :skip_feature, buffer: [], feature_bytes: feature_bytes}
    else
      slice = binary_part(bin, slice_start, slice_len)
      %{state | buffer: [slice | state.buffer], feature_bytes: feature_bytes}
    end
  end

  # Consumes a non-object array element up to the next top-level `,` or
  # `]`, honoring string/escape context so a comma inside a bare string
  # element never splits it in two.
  defp consume_junk(<<>>, state, emitted), do: {emitted, state}

  defp consume_junk(<<byte, rest::binary>>, %{in_string: true} = state, emitted) do
    consume_junk(rest, string_step(state, byte), emitted)
  end

  defp consume_junk(<<?", rest::binary>>, state, emitted) do
    consume_junk(rest, %{state | in_string: true}, emitted)
  end

  defp consume_junk(<<?,, rest::binary>>, state, emitted) do
    error = {:error, {:invalid_json, :non_object_feature}}
    consume(rest, %{state | mode: :between}, [error | emitted])
  end

  defp consume_junk(<<?], _rest::binary>>, state, emitted) do
    error = {:error, {:invalid_json, :non_object_feature}}
    {[error | emitted], %{state | mode: :done}}
  end

  defp consume_junk(<<_byte, rest::binary>>, state, emitted) do
    consume_junk(rest, state, emitted)
  end

  defp decode_feature(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  # JSON-aware seek: finds the `[` opening the array of a depth-1 key
  # named exactly `features`, never a string *value* that merely contains
  # or equals `"features"` (string and escape context is tracked; a
  # matched candidate is only accepted when a `:` follows, which only ever
  # follows a key). Returns the bytes strictly after that `[` so the
  # caller resumes scanning from the first feature (or `]` for an empty
  # collection). The whole (bounded, at most `@seek_limit_bytes`) buffer
  # is rescanned on each new chunk: simpler than carrying incremental
  # scanner state across chunks, and the cap keeps the rescans cheap.
  defp find_array_start(buffer),
    do: seek_scan(buffer, 0, %{depth: 0, in_string: false, escaped: false})

  defp seek_scan(buffer, offset, state) when offset < byte_size(buffer) do
    byte = :binary.at(buffer, offset)

    cond do
      state.in_string ->
        seek_scan(buffer, offset + 1, string_step(state, byte))

      byte == ?" and state.depth == 1 ->
        try_features_key(buffer, offset, state)

      true ->
        seek_scan(buffer, offset + 1, seek_step(state, byte))
    end
  end

  defp seek_scan(_buffer, _offset, _state), do: :not_found

  # One out-of-string byte of the header scan: string starts and
  # brace/bracket depth, everything else passes through.
  defp seek_step(state, ?"), do: %{state | in_string: true}
  defp seek_step(state, byte) when byte in [?{, ?[], do: %{state | depth: state.depth + 1}
  defp seek_step(state, byte) when byte in [?}, ?]], do: %{state | depth: state.depth - 1}
  defp seek_step(state, _byte), do: state

  # A `"` at depth 1: either the `features` key this scan is looking for,
  # or some other key/value string to skip over as a normal string.
  defp try_features_key(buffer, offset, state) do
    rest = binary_part(buffer, offset, byte_size(buffer) - offset)

    case rest do
      <<"\"features\"", after_key::binary>> ->
        case skip_to_bracket(after_key) do
          {:ok, array_rest} ->
            {:ok, array_rest}

          # `"features"` immediately followed by `,`/`}`/...: it was a
          # string *value*, not a key (a key is always followed by `:`).
          # Resume scanning right after the closing quote.
          :not_a_key ->
            seek_scan(buffer, offset + byte_size("\"features\""), state)

          :not_found ->
            :not_found
        end

      _other ->
        seek_scan(buffer, offset + 1, %{state | in_string: true})
    end
  end

  # After a confirmed `"features"` token: whitespace then `:` then
  # whitespace then `[` makes it the key this module wants. A missing `:`
  # means the token was a value (`:not_a_key`); a `:` followed by
  # something other than `[` is a genuinely unreadable file (the
  # `features` key does not hold an array); an exhausted buffer is simply
  # "wait for the next chunk" (`:not_found`).
  defp skip_to_bracket(bin), do: skip_ws_then(bin, :colon)

  defp skip_ws_then(<<c, rest::binary>>, expected) when c in [?\s, ?\n, ?\r, ?\t] do
    skip_ws_then(rest, expected)
  end

  defp skip_ws_then(<<?:, rest::binary>>, :colon), do: skip_ws_then(rest, :bracket)
  defp skip_ws_then(<<_c, _rest::binary>>, :colon), do: :not_a_key
  defp skip_ws_then(<<?[, rest::binary>>, :bracket), do: {:ok, rest}
  defp skip_ws_then(<<>>, _expected), do: :not_found

  defp skip_ws_then(_other, :bracket) do
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
