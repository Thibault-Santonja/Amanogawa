defmodule Amanogawa.Repo.Migrations.AddEventsQueryIndexes do
  use Ecto.Migration

  @moduledoc """
  Adds the index the critical query (issue #014,
  `Amanogawa.Atlas.EventQueries`) needed once measured against a synthetic
  420,000-row corpus: a partial btree matching `ORDER BY sitelink_count
  DESC, qid ASC WHERE geom IS NOT NULL` exactly.

  Without it, the world/full-range scenario (no bbox to narrow the scan)
  paid for a separate sort step over every geolocated row; with it, the
  planner walks the index in the exact output order and stops at `LIMIT`.
  See the moduledoc of `Amanogawa.Atlas.EventQueries` for the full
  methodology and measured timings.

  Two other candidates from the issue were measured and NOT added here:

    * a composite `(begin_year, sitelink_count DESC)` btree: the planner
      never chose it over this partial index or the existing GiST index on
      `geom` in any measured scenario, including the adversarial case it
      was meant for (a narrow year window at world-bbox scale); a range
      filter on `begin_year` cannot use a trailing `sitelink_count` key for
      a global sort, only within one exact `begin_year` value, so it does
      not help this query shape.
    * a plain (non-partial) `sitelink_count` index: already exists
      (`add_summary_columns_to_atlas_events` migration, #012), serving
      `Amanogawa.Atlas.list_events_to_enrich/1`, a query with no `geom IS
      NOT NULL` filter. Left untouched: it cannot be replaced by the
      partial index below, since PostgreSQL can only use a partial index
      when the query's `WHERE` clause is provable to imply the partial
      predicate.

  The existing GiST index on `geom` and plain btree on `begin_year`
  (`create_atlas_events` migration) are both still exercised by the
  planner for selective-bbox and narrow-time-window scenarios respectively
  and are kept as-is.
  """

  def change do
    create index(:events, ["sitelink_count DESC", :qid],
             where: "geom IS NOT NULL",
             name: :events_sitelink_count_qid_partial_index,
             prefix: "atlas"
           )
  end
end
