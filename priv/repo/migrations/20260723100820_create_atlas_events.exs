defmodule Amanogawa.Repo.Migrations.CreateAtlasEvents do
  use Ecto.Migration

  @moduledoc """
  Creates `atlas.events`, the read model row for a historical event.

  Begin/end dates are stored as flat `begin_*`/`end_*` columns rather than a
  composite type: this is the ADR 0006 decision for `HistoricalDate`, giving
  simple btree indexing and sorting while keeping the year/month/day/
  precision/calendar breakdown intact. `end_*` is fully nullable since most
  events are punctual.
  """

  def change do
    create table(:events, primary_key: false, prefix: "atlas") do
      add :id, :binary_id, primary_key: true

      add :qid, :string, null: false

      add :label_fr, :string
      add :label_en, :string
      add :description_fr, :text
      add :description_en, :text

      # Wikipedia summaries, populated by the enrichment pipeline (#012); nil
      # at import time.
      add :extract_fr, :text
      add :extract_en, :text
      add :wiki_url_fr, :string
      add :wiki_url_en, :string

      # Raw P31 class QID at this stage; mapping to a readable label is a
      # display concern, out of scope here.
      add :kind, :string

      add :begin_year, :integer, null: false
      add :begin_month, :integer
      add :begin_day, :integer
      add :begin_precision, :integer, null: false
      add :begin_calendar, :string

      add :end_year, :integer
      add :end_month, :integer
      add :end_day, :integer
      add :end_precision, :integer
      add :end_calendar, :string

      add :geom, :"geometry(Point,4326)"

      # Provenance of the geometry: most coordinates are inherited from the
      # event's place (P276 -> P625) rather than given directly (P625).
      add :location_source, :string

      # Proxy for importance, used to rank/limit events shown by zoom level.
      add :sitelink_count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:events, [:qid], prefix: "atlas")
    create index(:events, [:geom], using: :gist, prefix: "atlas")
    create index(:events, [:begin_year], prefix: "atlas")
  end
end
