defmodule Amanogawa.WikimediaUrl do
  @moduledoc """
  Validation of URLs pointing at Wikimedia properties: article links and
  image thumbnails.

  Deliberately a shared kernel (`.claude/rules/architecture.md`: contexts
  expose one public API module and never call another context's internal
  modules), not owned by `Amanogawa.Ingestion`: this module started there
  (ingestion is where such URLs first arrive, from Wikidata/Wikipedia
  payloads) but is also needed by `Amanogawa.Atlas` for defense-in-depth
  validation at the point data is written (`Amanogawa.Atlas.Event`
  changesets, `Amanogawa.Atlas.put_event_summary/2`), a second, independent
  bounded context. Calling `Amanogawa.Ingestion.WikimediaUrl` from `Atlas`
  would violate the "never call another context's internals" rule; moving
  the shared logic up to the application root (`Amanogawa.*`, alongside
  `Amanogawa.HistoricalDate`, itself already shared between the two
  contexts) is the documented way out, rather than duplicating the
  validation or laundering it through a facade function that would just
  forward to the exact same logic.

  A URL is accepted by `valid?/1` only when it is `https`, no longer than
  `#{inspect(2048)}` characters, and hosted on a Wikimedia domain
  (`*.wikipedia.org`, `*.wikimedia.org`, which covers
  `upload.wikimedia.org`). `valid_thumbnail?/1` is stricter still: only the
  single `upload.wikimedia.org` host, the one images are actually served
  from and the only host `img-src` allows in
  `AmanogawaWeb.Plugs.ContentSecurityPolicy`. Anything else, `http`,
  `javascript:`, an attacker-controlled host injected through a hostile
  SPARQL endpoint or Wikipedia response, an absurdly long value, is
  refused: callers either reject the whole binding (event article URLs,
  `Amanogawa.Ingestion.Wikidata.EventDecoder`) or drop the field
  (thumbnails, `Amanogawa.Ingestion.WikipediaClient.Summary`).
  """

  @max_length 2048

  @allowed_host_suffixes [".wikipedia.org", ".wikimedia.org"]
  @allowed_hosts ["wikipedia.org", "wikimedia.org"]

  @upload_host "upload.wikimedia.org"

  @doc """
  Whether `url` is an `https` URL on an allowed Wikimedia host, at most
  #{@max_length} characters long.

  Accepts any `*.wikipedia.org`/`*.wikimedia.org` host, including
  `upload.wikimedia.org`: suitable for article URLs. For thumbnails, prefer
  the stricter `valid_thumbnail?/1`.

  ## Examples

      iex> Amanogawa.WikimediaUrl.valid?("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      true

      iex> Amanogawa.WikimediaUrl.valid?("https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg")
      true

      iex> Amanogawa.WikimediaUrl.valid?("http://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      false

      iex> Amanogawa.WikimediaUrl.valid?("https://evil.example.com/wiki/Bataille_de_Marathon")
      false

  """
  @spec valid?(term()) :: boolean()
  def valid?(url) when is_binary(url) and byte_size(url) <= @max_length do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) -> allowed_host?(host)
      _ -> false
    end
  end

  def valid?(_url), do: false

  @doc """
  Whether `url` is an `https` URL specifically on the Wikimedia upload
  host (`#{@upload_host}`), at most #{@max_length} characters long.

  The only host thumbnails are ever allowed to point to: stricter than
  `valid?/1`, which also accepts `*.wikipedia.org` article hosts (not
  images). Matches `img-src` in `AmanogawaWeb.Plugs.ContentSecurityPolicy`
  exactly, by design: the two must never drift apart.

  ## Examples

      iex> Amanogawa.WikimediaUrl.valid_thumbnail?("https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg")
      true

      iex> Amanogawa.WikimediaUrl.valid_thumbnail?("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      false

  """
  @spec valid_thumbnail?(term()) :: boolean()
  def valid_thumbnail?(url) when is_binary(url) and byte_size(url) <= @max_length do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        String.downcase(host) == @upload_host

      _ ->
        false
    end
  end

  def valid_thumbnail?(_url), do: false

  @doc "Maximum accepted URL length, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  defp allowed_host?(host) do
    downcased = String.downcase(host)

    downcased in @allowed_hosts or
      Enum.any?(@allowed_host_suffixes, &String.ends_with?(downcased, &1))
  end
end
