defmodule Amanogawa.Ingestion.WikimediaUrl do
  @moduledoc """
  Validation of URLs ingested from external Wikidata/Wikipedia payloads
  before they are stored (article links, thumbnails).

  A URL is accepted only when it is `https`, no longer than
  `#{inspect(2048)}` characters, and hosted on a Wikimedia domain
  (`*.wikipedia.org`, `*.wikimedia.org`, which covers
  `upload.wikimedia.org`). Anything else, `http`, `javascript:`, an
  attacker-controlled host injected through a hostile SPARQL endpoint, an
  absurdly long value, is refused: callers either reject the whole binding
  (event article URLs, `Amanogawa.Ingestion.Wikidata.EventDecoder`) or drop
  the field (thumbnails, `Amanogawa.Ingestion.WikipediaClient.Summary`).
  """

  @max_length 2048

  @allowed_host_suffixes [".wikipedia.org", ".wikimedia.org"]
  @allowed_hosts ["wikipedia.org", "wikimedia.org"]

  @doc """
  Whether `url` is an `https` URL on an allowed Wikimedia host, at most
  #{@max_length} characters long.

  ## Examples

      iex> Amanogawa.Ingestion.WikimediaUrl.valid?("https://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      true

      iex> Amanogawa.Ingestion.WikimediaUrl.valid?("https://upload.wikimedia.org/wikipedia/commons/a/ab/Marathon.jpg")
      true

      iex> Amanogawa.Ingestion.WikimediaUrl.valid?("http://fr.wikipedia.org/wiki/Bataille_de_Marathon")
      false

      iex> Amanogawa.Ingestion.WikimediaUrl.valid?("https://evil.example.com/wiki/Bataille_de_Marathon")
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

  @doc "Maximum accepted URL length, in characters."
  @spec max_length() :: pos_integer()
  def max_length, do: @max_length

  defp allowed_host?(host) do
    downcased = String.downcase(host)

    downcased in @allowed_hosts or
      Enum.any?(@allowed_host_suffixes, &String.ends_with?(downcased, &1))
  end
end
