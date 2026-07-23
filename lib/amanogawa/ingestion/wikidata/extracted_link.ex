defmodule Amanogawa.Ingestion.Wikidata.ExtractedLink do
  @moduledoc """
  A single typed relation between two events, decoded from a Wikidata
  SPARQL result by `Amanogawa.Ingestion.Wikidata.LinkDecoder`, ready to be
  handed to `Amanogawa.Atlas.upsert_event_links/1` by the import worker
  (`Amanogawa.Ingestion.Workers.ImportLinks`).

  `property` carries the originating Wikidata property (`"P361"`,
  `"P155"`, `"P156"`, `"P793"` or `"P1344"`) for metrics only
  (`Amanogawa.Ingestion.Workers.ImportLinks`'s `by_property` breakdown): it
  plays no role in `Amanogawa.Atlas.upsert_event_links/1`, which only reads
  `source_qid`, `target_qid` and `type`.
  """

  @enforce_keys [:source_qid, :target_qid, :type, :property]
  defstruct [:source_qid, :target_qid, :type, :property]

  @typedoc "The subset of `Amanogawa.Atlas.EventLink.link_type()` this decoder produces."
  @type link_type :: :part_of | :follows | :significant

  @type t :: %__MODULE__{
          source_qid: String.t(),
          target_qid: String.t(),
          type: link_type(),
          property: String.t()
        }
end
