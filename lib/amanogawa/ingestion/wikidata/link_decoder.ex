defmodule Amanogawa.Ingestion.Wikidata.LinkDecoder do
  @moduledoc """
  Decodes a `Amanogawa.Ingestion.SparqlClient.Result` produced by
  `Amanogawa.Ingestion.Wikidata.Templates.links_page/1` into a
  deduplicated list of `Amanogawa.Ingestion.Wikidata.ExtractedLink`.

  ## Property mapping

  | Property | Wikidata meaning | Normalized link |
  |---|---|---|
  | `P361` (part of) | `A` is part of `B` | `source: A, target: B, type: :part_of` |
  | `P155` (follows) | `A` follows `B` | `source: A, target: B, type: :follows` |
  | `P156` (followed by) | `B` follows `A` (direction inverted) | `source: B, target: A, type: :follows` |
  | `P793` (significant event) | `B` is significant for `A` | `source: A, target: B, type: :significant` |
  | `P1344` (participant of) | `A` participates in `B`, read as inclusion | `source: A, target: B, type: :part_of` |

  `P1344` between two events is mapped to `:part_of` rather than left
  unmapped: Wikidata does not distinguish "participated in alongside other
  forces" from "was a sub-event of", and `:part_of` is the closer reading
  for the map/timeline hierarchy this project displays
  (`docs/features/002-ingestion-wikidata/006-import-relations.md`).

  `P155`/`P156` describe the same chronological fact from either side, so
  after normalization a page carrying both `A P156 B` and `B P155 A` (a
  real, if redundant, Wikidata pattern) collapses to a single link:

      iex> result = %Amanogawa.Ingestion.SparqlClient.Result{
      ...>   variables: ["source", "target", "property"],
      ...>   bindings: [
      ...>     %{
      ...>       "source" => %{value: "http://www.wikidata.org/entity/Q178809", type: :uri, datatype: nil, lang: nil},
      ...>       "target" => %{value: "http://www.wikidata.org/entity/Q508496", type: :uri, datatype: nil, lang: nil},
      ...>       "property" => %{value: "P156", type: :literal, datatype: nil, lang: nil}
      ...>     }
      ...>   ]
      ...> }
      iex> {[link], 0} = Amanogawa.Ingestion.Wikidata.LinkDecoder.decode(result)
      iex> {link.source_qid, link.target_qid, link.type}
      {"Q508496", "Q178809", :follows}

  ## Rejection and self-links

  A binding is rejected, never crashed on, when it lacks a parsable
  source/target QID or carries an unrecognized property. A self-link
  (`source == target`, found in Wikidata as a data-quality artifact) is
  rejected the same way, after the property mapping and direction
  normalization have been applied (so a `P156` self-link is caught on its
  normalized, not its raw, pair).
  """

  alias Amanogawa.Ingestion.SparqlClient.Result
  alias Amanogawa.Ingestion.Wikidata.ExtractedLink

  @qid_uri_regex ~r{\Ahttp://www\.wikidata\.org/entity/(Q\d+)\z}

  @doc """
  Decodes every binding of `result` into a deduplicated list of
  `ExtractedLink`.

  Returns `{links, rejected_count}`: `links` deduplicated on
  `(source_qid, target_qid, type)` and free of self-links, `rejected_count`
  the number of bindings dropped for lacking a parsable source/target QID,
  carrying an unrecognized property, or describing a self-link. Never
  raises: a rejected binding never affects the rest of the page.
  """
  @spec decode(Result.t()) :: {[ExtractedLink.t()], non_neg_integer()}
  def decode(%Result{bindings: bindings}) do
    {links, rejected} =
      Enum.reduce(bindings, {[], 0}, fn binding, {links, rejected} ->
        case decode_binding(binding) do
          {:ok, link} -> {[link | links], rejected}
          :error -> {links, rejected + 1}
        end
      end)

    deduplicated =
      links
      |> Enum.reverse()
      |> Enum.uniq_by(&{&1.source_qid, &1.target_qid, &1.type})

    {deduplicated, rejected}
  end

  defp decode_binding(binding) do
    with {:ok, source_qid} <- extract_qid(binding, "source"),
         {:ok, target_qid} <- extract_qid(binding, "target"),
         {:ok, property} <- fetch_value(binding, "property"),
         {:ok, {mapped_source, mapped_target, type}} <-
           map_property(property, source_qid, target_qid) do
      build_link(mapped_source, mapped_target, type, property)
    else
      :error -> :error
    end
  end

  defp build_link(qid, qid, _type, _property), do: :error

  defp build_link(source_qid, target_qid, type, property) do
    {:ok,
     %ExtractedLink{
       source_qid: source_qid,
       target_qid: target_qid,
       type: type,
       property: property
     }}
  end

  @spec map_property(String.t(), String.t(), String.t()) ::
          {:ok, {String.t(), String.t(), ExtractedLink.link_type()}} | :error
  defp map_property("P361", source_qid, target_qid), do: {:ok, {source_qid, target_qid, :part_of}}
  defp map_property("P155", source_qid, target_qid), do: {:ok, {source_qid, target_qid, :follows}}
  defp map_property("P156", source_qid, target_qid), do: {:ok, {target_qid, source_qid, :follows}}

  defp map_property("P793", source_qid, target_qid),
    do: {:ok, {source_qid, target_qid, :significant}}

  defp map_property("P1344", source_qid, target_qid),
    do: {:ok, {source_qid, target_qid, :part_of}}

  defp map_property(_unknown, _source_qid, _target_qid), do: :error

  defp extract_qid(binding, key) do
    with {:ok, uri} <- fetch_value(binding, key),
         [_, qid] <- Regex.run(@qid_uri_regex, uri) do
      {:ok, qid}
    else
      _ -> :error
    end
  end

  defp fetch_value(binding, key) do
    case Map.fetch(binding, key) do
      {:ok, %{value: value}} -> {:ok, value}
      :error -> :error
    end
  end
end
