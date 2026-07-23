defmodule Amanogawa.Ingestion.WikipediaClient do
  @moduledoc """
  Port for fetching a page summary from the Wikipedia REST API
  (`page/summary`, see ADR 0003).

  This behaviour is the hexagonal boundary between the summaries enrichment
  worker and the external Wikipedia service. Consumers depend only on this
  behaviour, never on a concrete adapter: the adapter used at runtime is
  resolved through `Application.get_env(:amanogawa, :wikipedia_client)`, and
  tests use `Amanogawa.Ingestion.WikipediaClientMock` (Mox).

  An adapter never leaks transport concerns (HTTP status codes, raw JSON
  shapes) past its boundary: it returns either a `Summary` struct or one of
  the tagged errors below.
  """

  alias Amanogawa.Ingestion.WikipediaClient.Summary

  @typedoc """
  Tagged errors returned by a `WikipediaClient` adapter.

    * `:not_found` - no article exists at this title (HTTP 404).
    * `{:rate_limited, retry_after_seconds}` - the endpoint kept responding
      429 past the adapter's retry budget; `retry_after_seconds` carries the
      last `Retry-After` value seen, or `nil` when the endpoint did not send
      one.
    * `:timeout` - the request did not complete within the configured
      receive timeout.
    * `{:http_error, status}` - the endpoint responded with a non-2xx,
      non-404, non-429 HTTP status.
    * `{:transport_error, reason}` - any other connection-level failure
      (DNS, connection refused, TLS, ...).
    * `{:decode_error, reason}` - the response body was not a valid
      `page/summary` JSON document.
  """
  @type error ::
          :not_found
          | {:rate_limited, pos_integer() | nil}
          | :timeout
          | {:http_error, pos_integer()}
          | {:transport_error, term()}
          | {:decode_error, term()}

  @doc """
  Fetches the summary of `title` in `lang`.

  `Amanogawa.Ingestion.Workers.EnrichSummaries` picks `lang` per the ADR
  0003 policy (fr prioritized, en fallback) and derives `title` from the
  event's stored `wiki_url_fr`/`wiki_url_en` with `title_from_wiki_url/1`.
  An adapter re-encodes `title` for the request path; the caller never
  builds a URL itself.
  """
  @callback fetch_summary(lang :: :fr | :en, title :: String.t()) ::
              {:ok, Summary.t()} | {:error, error()}

  @doc """
  Extracts the plain article title from a stored Wikipedia article URL: the
  URL's path with its `/wiki/` prefix trimmed, URL-decoded. Working on the
  parsed path (never on "the last `/`-separated segment") preserves titles
  that legitimately contain a slash, like `Naissance/Fêtes`.

  Pure and total: never raises, whatever shape the URL carries.
  `URI.decode/1` itself never raises on malformed percent-encoding (it
  passes an invalid escape through unchanged); the real failure mode is a
  percent-encoded byte sequence that decodes to something that is not
  valid UTF-8 (e.g. a raw, non-UTF-8 `%FF`). Wikidata's `schema:about`
  article URLs are always well-formed absolute URLs in practice, but this
  stays defensive against that case by falling back to the raw (still
  usable) segment rather than handing the worker a corrupt title. A URL
  without a `/wiki/` path falls back to the last path segment.

      iex> Amanogawa.Ingestion.WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      "Bataille_de_Marathon"

      iex> Amanogawa.Ingestion.WikipediaClient.title_from_wiki_url("https://en.wikipedia.org/wiki/Battle_of_Agincourt")
      "Battle_of_Agincourt"

      iex> Amanogawa.Ingestion.WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/Charles_%27le_T%C3%A9m%C3%A9raire%27")
      "Charles_'le_Téméraire'"

      iex> Amanogawa.Ingestion.WikipediaClient.title_from_wiki_url("https://fr.wikipedia.org/wiki/Sege/Histoire_d%27un_titre")
      "Sege/Histoire_d'un_titre"

  """
  @spec title_from_wiki_url(String.t()) :: String.t()
  def title_from_wiki_url(wiki_url) when is_binary(wiki_url) do
    segment = title_segment(wiki_url)
    decoded = URI.decode(segment)

    if String.valid?(decoded), do: decoded, else: segment
  end

  defp title_segment(wiki_url) do
    case URI.parse(wiki_url).path do
      "/wiki/" <> title -> title
      path -> (path || wiki_url) |> String.split("/") |> List.last() || ""
    end
  end

  defmodule Summary do
    @moduledoc """
    A decoded Wikipedia page summary (CC BY-SA 4.0): the data the
    enrichment worker stores through `Amanogawa.Atlas.put_event_summary/2`.

    `decode/2` is shared, endpoint-agnostic decoding logic for the
    `page/summary` JSON shape, reused by `Amanogawa.Ingestion.
    WikipediaClient.Rest` and by its tests.
    """

    alias Amanogawa.Ingestion.WikimediaUrl

    @enforce_keys [:title, :extract, :article_url, :lang]
    defstruct [:title, :description, :extract, :thumbnail_url, :article_url, :lang]

    @type t :: %__MODULE__{
            title: String.t(),
            description: String.t() | nil,
            extract: String.t(),
            thumbnail_url: String.t() | nil,
            article_url: String.t(),
            lang: :fr | :en
          }

    @max_extract_length 8192

    @doc """
    Decodes a `page/summary` response body into a `Summary`.

    Accepts either the raw JSON string as received over the wire, or an
    already-decoded map. Requires `title`, `extract` (the plain text
    summary, never `extract_html`: `.claude/rules/architecture.md` keeps
    display markup out of stored data) and a desktop `content_urls.desktop.page`
    (the canonical article URL, mandatory for CC BY-SA attribution).
    `thumbnail.source` is optional: absent when the article has no image.

    Input bounds: `extract` is truncated to #{@max_extract_length}
    characters (an extract is a summary, anything longer is an anomaly not
    worth failing the event over); `thumbnail.source` must satisfy
    `Amanogawa.Ingestion.WikimediaUrl.valid?/1` (https, Wikimedia host,
    bounded length) or the field is dropped (`nil`), never the whole
    summary.

    Returns `{:error, reason}` when the document does not parse as JSON, or
    parses but is missing one of the required fields.
    """
    @spec decode(String.t() | map(), :fr | :en) :: {:ok, t()} | {:error, term()}
    def decode(json, lang) when is_binary(json) and lang in [:fr, :en] do
      case Jason.decode(json) do
        {:ok, decoded} -> decode(decoded, lang)
        {:error, reason} -> {:error, reason}
      end
    end

    def decode(%{"title" => title, "extract" => extract} = decoded, lang)
        when is_binary(title) and is_binary(extract) and lang in [:fr, :en] do
      case article_url(decoded) do
        article_url when is_binary(article_url) ->
          {:ok,
           %__MODULE__{
             title: title,
             description: Map.get(decoded, "description"),
             extract: truncate_extract(extract),
             thumbnail_url: thumbnail_url(decoded),
             article_url: article_url,
             lang: lang
           }}

        nil ->
          {:error, :missing_article_url}
      end
    end

    def decode(%{} = _decoded, _lang), do: {:error, :invalid_summary_shape}

    defp article_url(decoded), do: get_in(decoded, ["content_urls", "desktop", "page"])

    defp truncate_extract(extract) do
      if String.length(extract) > @max_extract_length do
        String.slice(extract, 0, @max_extract_length)
      else
        extract
      end
    end

    # A thumbnail that is not an https Wikimedia URL (or is absurdly long)
    # is dropped, never a reason to lose the summary: the extract is the
    # data, the image is decoration.
    defp thumbnail_url(decoded) do
      url = get_in(decoded, ["thumbnail", "source"])
      if WikimediaUrl.valid?(url), do: url, else: nil
    end
  end
end
