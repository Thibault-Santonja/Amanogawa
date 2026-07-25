defmodule Amanogawa.Repo.Migrations.AddOverridesColumnsToAtlasEvents do
  use Ecto.Migration

  @moduledoc """
  Adds the two columns the layered-data resolution mechanism needs on
  `atlas.events` (issue #034, F08 overview's "colonne résolue... maintenue
  par le contexte Contributions via l'API publique d'Atlas"):

    * `overridden_fields` (`text[]`, business field names): which fields
      currently carry an accepted contribution override rather than their
      Wikidata-sourced value. Read by `Amanogawa.Atlas.upsert_events/1`
      (#035) to decide, column by column, whether to keep the value in
      place or take Wikidata's incoming one.
    * `origin` (`:wikidata` | `:contribution`, default `:wikidata`): lets a
      row be told apart as community-contributed
      (`Amanogawa.Atlas.create_contributed_event/1`) without inspecting the
      `qid` format.

  No constraint on the `qid` format here: the extended pattern (`Q\\d+` or
  `L<uuid hex>`) is enforced in `Amanogawa.Atlas.Event.changeset/2`, exactly
  as the existing `Q\\d+`-only format was before this migration.
  """

  def change do
    alter table(:events, prefix: "atlas") do
      add :overridden_fields, {:array, :string}, null: false, default: []
      add :origin, :string, null: false, default: "wikidata"
    end
  end
end
