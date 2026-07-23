defmodule Amanogawa.Ingestion.Wikidata.ExtractedEvent do
  @moduledoc """
  A single historical event as decoded from a Wikidata SPARQL result, ready
  to be handed to `Amanogawa.Atlas.upsert_events/1` by the import worker
  (#010).

  This struct is a pure Ingestion-domain value object: it knows nothing
  about `Amanogawa.Atlas.Event`'s storage shape (flat `begin_*`/`end_*`
  columns), only about the normalized data itself. Dates are carried as
  `Amanogawa.HistoricalDate` structs, geometry as a `Geo.Point`.
  """

  alias Amanogawa.HistoricalDate

  @enforce_keys [:qid, :location_source]
  defstruct [
    :qid,
    :label_fr,
    :label_en,
    :description_fr,
    :description_en,
    :kind,
    :begin,
    :end,
    :geom,
    :location_source,
    :wiki_url_fr,
    :wiki_url_en,
    sitelink_count: 0
  ]

  @typedoc "Provenance of `geom`: direct (P625) or inherited from the place (P276 -> P625)."
  @type location_source :: :direct | :place

  @type t :: %__MODULE__{
          qid: String.t(),
          label_fr: String.t() | nil,
          label_en: String.t() | nil,
          description_fr: String.t() | nil,
          description_en: String.t() | nil,
          kind: String.t() | nil,
          begin: HistoricalDate.t() | nil,
          end: HistoricalDate.t() | nil,
          geom: Geo.Point.t() | nil,
          location_source: location_source(),
          wiki_url_fr: String.t() | nil,
          wiki_url_en: String.t() | nil,
          sitelink_count: non_neg_integer()
        }
end
