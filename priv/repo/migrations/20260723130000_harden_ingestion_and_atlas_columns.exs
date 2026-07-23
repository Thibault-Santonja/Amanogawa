defmodule Amanogawa.Repo.Migrations.HardenIngestionAndAtlasColumns do
  use Ecto.Migration

  @moduledoc """
  Additive hardening pass over `atlas.events` and `ingestion.sync_runs`
  (feature 002 review findings):

    * `atlas.events` text-ish columns whose real-world values are unbounded
      (Wikidata labels, article URLs, thumbnails, class QIDs) move from
      `varchar(255)` to `text`, so a legitimate long value can never fail an
      insert. Input bounds are enforced at decode time
      (`Amanogawa.Ingestion.Wikidata.EventDecoder`,
      `Amanogawa.Ingestion.WikipediaClient.Summary`), not by column width.
    * `begin_year`/`end_year` move to `bigint`: the domain bound is
      [-13 800 000 000, 3000] (`Amanogawa.HistoricalDate`), far outside
      `int4` range on the lower end.
    * `ingestion.sync_runs` gains an `options` jsonb column persisting the
      run's start options (`limit`, `dry_run`, ...), so resuming a failed
      run replays the exact options it was started with.
    * A partial unique index guarantees at most one `running` run per kind
      at the database level, backing the facade's application-level check.
  """

  def change do
    alter table(:events, prefix: "atlas") do
      modify :label_fr, :text, from: :string
      modify :label_en, :text, from: :string
      modify :wiki_url_fr, :text, from: :string
      modify :wiki_url_en, :text, from: :string
      modify :thumbnail_url, :text, from: :string
      modify :kind, :text, from: :string

      modify :begin_year, :bigint, null: false, from: {:integer, null: false}
      modify :end_year, :bigint, from: :integer
    end

    alter table(:sync_runs, prefix: "ingestion") do
      add :options, :map, null: false, default: %{}
    end

    create unique_index(:sync_runs, [:kind],
             where: "status = 'running'",
             name: :sync_runs_running_kind_index,
             prefix: "ingestion"
           )
  end
end
