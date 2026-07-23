defmodule Amanogawa.Repo.Migrations.AddSummaryColumnsToAtlasEvents do
  use Ecto.Migration

  @moduledoc """
  Adds the Wikipedia enrichment cache columns to `atlas.events` (#012):
  `extract_fetched_at` (last enrichment attempt, successful or not: this is
  the cache freshness marker, never re-fetched before
  `summary_max_age_days`), `thumbnail_url`, and `extract_attribution`
  (jsonb: `article_url`, `license`, `lang`, CC BY-SA 4.0 attribution).
  Additive only; `extract_fr`/`extract_en` and `wiki_url_fr`/`wiki_url_en`
  already exist (migration 20260723100820).

  These three columns, like `extract_fr`/`extract_en`, stay outside
  `Amanogawa.Atlas.@wikidata_columns`: a Wikidata upsert (#007) must never
  overwrite enrichment data written by this pipeline.
  """

  def change do
    alter table(:events, prefix: "atlas") do
      add :extract_fetched_at, :utc_datetime
      add :thumbnail_url, :string
      add :extract_attribution, :map
    end

    # Backs `Amanogawa.Atlas.list_events_to_enrich/1`'s `ORDER BY
    # sitelink_count DESC` over the whole events table.
    create index(:events, [:sitelink_count], prefix: "atlas")
  end
end
