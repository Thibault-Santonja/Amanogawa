defmodule Amanogawa.Repo.Migrations.AddAreaKm2ToAtlasBorders do
  use Ecto.Migration

  @moduledoc """
  Adds `atlas.borders.area_km2`, the area of `geom_medium` (the level the
  web edge serves) in square kilometers, precomputed at import time by
  `Amanogawa.Atlas.BorderQueries.insert_batch/3` instead of recomputed by
  every `GET /api/borders` request (F05 quality finding).

  Purely additive; nullable because existing rows (if any) predate the
  computation. `mix amanogawa.import.cliopatria` /
  `mix amanogawa.import.historical_basemaps` re-imports replace every row
  of their source with the value filled in, so a backfill migration is
  not needed: the import IS the backfill.
  """

  def change do
    alter table(:borders, prefix: "atlas") do
      add :area_km2, :float
    end
  end
end
