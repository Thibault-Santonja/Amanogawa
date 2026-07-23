defmodule Amanogawa.Logging.JSONFormatterTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Amanogawa.Logging.JSONFormatter

  @timestamp {{2026, 7, 23}, {10, 30, 45, 123}}

  defp decode(line) do
    line |> IO.iodata_to_binary() |> String.trim_trailing("\n") |> Jason.decode!()
  end

  describe "happy path" do
    test "produces decodable JSON with timestamp, level, message and request_id" do
      line = JSONFormatter.format(:info, "hello", @timestamp, request_id: "req-123")

      assert %{
               "timestamp" => "2026-07-23T10:30:45.123Z",
               "level" => "info",
               "message" => "hello",
               "request_id" => "req-123"
             } = decode(line)
    end

    test "omits request_id entirely when absent from metadata" do
      decoded = JSONFormatter.format(:warning, "no request", @timestamp, []) |> decode()

      refute Map.has_key?(decoded, "request_id")
    end

    test "carries other metadata under a metadata key" do
      decoded =
        JSONFormatter.format(:error, "boom", @timestamp, module: Foo, line: 42) |> decode()

      assert decoded["metadata"] == %{"module" => "Elixir.Foo", "line" => 42}
    end
  end

  describe "edge case: non-serializable metadata" do
    test "a pid is rendered via inspect/1" do
      decoded = JSONFormatter.format(:info, "with pid", @timestamp, pid: self()) |> decode()

      assert decoded["metadata"]["pid"] =~ ~r/^#PID</
    end

    test "a reference is rendered via inspect/1" do
      decoded =
        JSONFormatter.format(:info, "with ref", @timestamp, ref: make_ref()) |> decode()

      assert decoded["metadata"]["ref"] =~ ~r/^#Reference</
    end

    test "a struct is rendered via inspect/1" do
      decoded =
        JSONFormatter.format(:info, "with struct", @timestamp, range: 1..3) |> decode()

      assert decoded["metadata"]["range"] == "1..3"
    end

    test "a printable charlist is rendered as its string" do
      decoded =
        JSONFormatter.format(:info, "with charlist", @timestamp, chars: ~c"abc") |> decode()

      assert decoded["metadata"]["chars"] == "abc"
    end

    test "a non-printable integer list stays a JSON array" do
      decoded =
        JSONFormatter.format(:info, "with ints", @timestamp, codes: [1, 2, 3]) |> decode()

      assert decoded["metadata"]["codes"] == [1, 2, 3]
    end

    test "an atom value is rendered as a plain string" do
      decoded = JSONFormatter.format(:info, "with atom", @timestamp, kind: :timeout) |> decode()

      assert decoded["metadata"]["kind"] == "timeout"
    end

    test "a map value with a non-atom, non-binary key never crashes" do
      decoded =
        JSONFormatter.format(:info, "with odd key", @timestamp, oddities: %{{1, 2} => "x"})
        |> decode()

      assert decoded["metadata"]["oddities"] == %{"{1, 2}" => "x"}
    end

    test "a tuple is rendered via inspect/1" do
      decoded =
        JSONFormatter.format(:info, "with tuple", @timestamp, pair: {:ok, 1}) |> decode()

      assert decoded["metadata"]["pair"] == "{:ok, 1}"
    end
  end

  describe "security: sensitive metadata keys are redacted" do
    test "password, secret, token, authorization and key variants are redacted" do
      decoded =
        JSONFormatter.format(:info, "redacted", @timestamp,
          password: "hunter2",
          db_secret: "s3cret",
          auth_token: "tok",
          authorization: "Bearer abc",
          api_key: "k-123",
          secret_key_base: "skb"
        )
        |> decode()

      for key <- ~w(password db_secret auth_token authorization api_key secret_key_base) do
        assert decoded["metadata"][key] == "[REDACTED]"
      end
    end

    test "redaction applies inside nested maps and keyword values" do
      decoded =
        JSONFormatter.format(:info, "nested", @timestamp,
          opts: %{password: "x", host: "db.internal"},
          conn: [token: "t", port: 5432]
        )
        |> decode()

      assert decoded["metadata"]["opts"]["password"] == "[REDACTED]"
      assert decoded["metadata"]["opts"]["host"] == "db.internal"
      assert decoded["metadata"]["conn"]["token"] == "[REDACTED]"
      assert decoded["metadata"]["conn"]["port"] == 5432
    end

    test "ordinary keys are never redacted" do
      decoded =
        JSONFormatter.format(:info, "plain", @timestamp,
          module: Foo,
          request_path: "/health",
          monkey: "still here"
        )
        |> decode()

      assert decoded["metadata"]["module"] == "Elixir.Foo"
      assert decoded["metadata"]["request_path"] == "/health"
      assert decoded["metadata"]["monkey"] == "still here"
    end
  end

  describe "single line invariant" do
    test "a message containing newlines still yields exactly one JSON line" do
      line =
        JSONFormatter.format(:error, "line1\nline2\nline3", @timestamp, [])
        |> IO.iodata_to_binary()

      assert String.ends_with?(line, "\n")

      body = String.trim_trailing(line, "\n")
      refute body =~ "\n"
      assert Jason.decode!(body)["message"] == "line1\nline2\nline3"
    end
  end

  describe "error case: pathological input" do
    test "a non-UTF-8 binary message never crashes the formatter" do
      line = JSONFormatter.format(:error, <<255, 254, 253>>, @timestamp, [])

      assert %{"message" => message} = decode(line)
      assert is_binary(message)
    end

    test "a non-UTF-8 binary in metadata never crashes the formatter" do
      decoded =
        JSONFormatter.format(:error, "ok", @timestamp, bad: <<255, 254>>) |> decode()

      assert is_binary(decoded["metadata"]["bad"])
    end

    test "a deeply nested term is bounded, never crashes, never blows the stack" do
      deeply_nested = Enum.reduce(1..500, :leaf, fn _n, acc -> [acc] end)

      line = JSONFormatter.format(:error, "deep", @timestamp, nested: deeply_nested)

      assert %{"message" => "deep"} = decode(line)
    end

    test "an iolist message never crashes the formatter" do
      line = JSONFormatter.format(:info, ["hello ", ["world", [?!]]], @timestamp, [])

      assert %{"message" => "hello world!"} = decode(line)
    end
  end

  describe "limit case: depth bound" do
    test "a term nested exactly at the bound is preserved, one past it is truncated" do
      at_bound = %{a: %{b: %{c: %{d: %{e: %{f: "still here"}}}}}}
      decoded = JSONFormatter.format(:info, "depth", @timestamp, value: at_bound) |> decode()

      assert get_in(decoded, ["metadata", "value", "a", "b", "c", "d", "e", "f"]) ==
               "still here"

      one_past = %{a: %{b: %{c: %{d: %{e: %{f: %{g: "too deep"}}}}}}}
      decoded = JSONFormatter.format(:info, "depth", @timestamp, value: one_past) |> decode()

      assert get_in(decoded, ["metadata", "value", "a", "b", "c", "d", "e", "f"]) == "…"
    end
  end

  describe "property: arbitrary metadata always yields decodable JSON" do
    property "for any generated term as a metadata value, the output is valid JSON" do
      check all(key <- StreamData.atom(:alphanumeric), value <- arbitrary_term()) do
        line = JSONFormatter.format(:info, "property", @timestamp, [{key, value}])

        assert %{"level" => "info"} = decode(line)
      end
    end
  end

  # A bounded generator over "hostile" Elixir terms: atoms, integers,
  # floats, binaries (including invalid UTF-8), pids, references, and
  # composites (lists, tuples, maps) of those, capped in depth so the
  # property test itself stays fast.
  defp arbitrary_term do
    leaf =
      StreamData.one_of([
        StreamData.integer(),
        StreamData.float(),
        StreamData.boolean(),
        StreamData.atom(:alphanumeric),
        StreamData.binary(),
        StreamData.constant(self()),
        StreamData.constant(make_ref()),
        StreamData.constant(nil)
      ])

    StreamData.tree(leaf, fn leaf_generator ->
      StreamData.one_of([
        StreamData.list_of(leaf_generator, max_length: 4),
        StreamData.map_of(StreamData.atom(:alphanumeric), leaf_generator, max_length: 4),
        StreamData.tuple({leaf_generator, leaf_generator})
      ])
    end)
  end
end
