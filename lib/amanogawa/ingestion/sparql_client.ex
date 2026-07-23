defmodule Amanogawa.Ingestion.SparqlClient do
  @moduledoc """
  Port for executing SPARQL queries against a triple store.

  This behaviour is the hexagonal boundary between the ingestion pipelines
  and the external SPARQL endpoints (QLever for heavy extractions, WDQS for
  small fresh queries). Consumers depend only on this behaviour, never on a
  concrete adapter: the adapter used at runtime is resolved through
  `Application.get_env(:amanogawa, :sparql_client)`, and tests use
  `Amanogawa.Ingestion.SparqlClientMock` (Mox).

  An adapter never leaks transport concerns (HTTP status codes, raw JSON
  shapes) past its boundary: it returns either a normalized `Result` struct
  or one of the tagged errors below.
  """

  alias Amanogawa.Ingestion.SparqlClient.Result

  @typedoc """
  Tagged errors returned by a `SparqlClient` adapter.

    * `{:http_error, status}` - the endpoint responded with a non-2xx,
      non-429 HTTP status.
    * `{:rate_limited, retry_after_seconds}` - the endpoint kept responding
      429 past the adapter's retry budget; `retry_after_seconds` carries the
      last `Retry-After` value seen, or `nil` when the endpoint did not send
      one.
    * `:timeout` - the request did not complete within the configured
      receive timeout.
    * `{:transport_error, reason}` - any other connection-level failure
      (DNS, connection refused, TLS, ...).
    * `{:decode_error, reason}` - the response body was not a valid
      `application/sparql-results+json` document.
  """
  @type error ::
          {:http_error, pos_integer()}
          | {:rate_limited, pos_integer() | nil}
          | :timeout
          | {:transport_error, term()}
          | {:decode_error, term()}

  @doc """
  Executes a SPARQL query and returns its normalized result.

  `sparql` must be a fully built, already-vetted query string (see
  `.claude/rules/security.md`: SPARQL is always built from vetted templates,
  never string-interpolated from user input). `opts` carries per-call
  overrides (timeouts, endpoint URL, ...); adapters fall back to their own
  configuration when an option is not given.
  """
  @callback query(sparql :: String.t(), opts :: keyword()) ::
              {:ok, Result.t()} | {:error, error()}

  defmodule Result do
    @moduledoc """
    Normalized result of a SPARQL query, decoded from the standard
    [SPARQL 1.1 Query Results JSON Format](https://www.w3.org/TR/sparql11-results-json/).

    Decoding is deliberately endpoint-agnostic: any adapter (QLever today,
    WDQS tomorrow) can reuse `decode/1` because the wire format is a W3C
    standard, not a QLever quirk.
    """

    @enforce_keys [:variables, :bindings]
    defstruct [:variables, :bindings]

    @typedoc "The RDF term kind of a bound value."
    @type value_type :: :uri | :literal | :bnode

    @typedoc "A single bound value, as found under a variable name in a binding."
    @type binding_value :: %{
            value: String.t(),
            type: value_type(),
            datatype: String.t() | nil,
            lang: String.t() | nil
          }

    @typedoc "One solution row: variable name to bound value."
    @type binding :: %{optional(String.t()) => binding_value()}

    @type t :: %__MODULE__{
            variables: [String.t()],
            bindings: [binding()]
          }

    @doc """
    Decodes a SPARQL 1.1 Query Results JSON Format document into a `Result`.

    Accepts either the raw JSON string as received over the wire, or an
    already-decoded map (Req may auto-decode `+json` bodies depending on the
    response `content-type`; both inputs are handled identically so the
    adapter does not need to know which one it got).

    Returns `{:error, reason}` when the document does not parse as JSON, or
    parses but does not match the expected `head`/`results` shape. Malformed
    individual bindings (missing `type` or `value`) raise: they indicate a
    document that violates the format contract, and are expected to be
    caught at the adapter's system boundary and converted to a tagged
    `:decode_error`.

        iex> Amanogawa.Ingestion.SparqlClient.Result.decode(
        ...>   ~s({"head":{"vars":["e"]},"results":{"bindings":[]}})
        ...> )
        {:ok, %Amanogawa.Ingestion.SparqlClient.Result{variables: ["e"], bindings: []}}

    """
    @spec decode(String.t() | map()) :: {:ok, t()} | {:error, term()}
    def decode(json) when is_binary(json) do
      case Jason.decode(json) do
        {:ok, decoded} -> decode(decoded)
        {:error, reason} -> {:error, reason}
      end
    end

    def decode(%{"head" => %{"vars" => variables}, "results" => %{"bindings" => bindings}})
        when is_list(variables) and is_list(bindings) do
      {:ok, %__MODULE__{variables: variables, bindings: Enum.map(bindings, &decode_binding/1)}}
    end

    def decode(%{} = _decoded), do: {:error, :invalid_result_shape}

    @doc """
    Same as `decode/1`, raising on any error instead of returning a tagged
    tuple. Meant for test fixtures, where a malformed fixture is a bug in
    the fixture itself.
    """
    @spec decode!(String.t() | map()) :: t()
    def decode!(json) do
      case decode(json) do
        {:ok, result} -> result
        {:error, reason} -> raise "invalid SPARQL results JSON: #{inspect(reason)}"
      end
    end

    defp decode_binding(binding) when is_map(binding) do
      Map.new(binding, fn {name, value} -> {name, decode_binding_value(value)} end)
    end

    defp decode_binding_value(%{"type" => type, "value" => value} = raw) do
      %{
        value: value,
        type: decode_type(type),
        datatype: Map.get(raw, "datatype"),
        lang: Map.get(raw, "xml:lang")
      }
    end

    defp decode_type("uri"), do: :uri
    defp decode_type("bnode"), do: :bnode
    # SPARQL 1.1 uses "literal" (with an optional "datatype"); some older
    # endpoints still emit the pre-1.1 "typed-literal". Both are literals.
    defp decode_type(_literal_or_typed_literal), do: :literal
  end
end
