# Defines the Postgrex type module used by Amanogawa.Repo so that PostGIS
# geometry values are encoded and decoded as Geo structs (SRID 4326 project-wide).
# Wired in config/config.exs via the Repo `:types` option.
Postgrex.Types.define(
  Amanogawa.PostgresTypes,
  [Geo.PostGIS.Extension] ++ Ecto.Adapters.Postgres.extensions(),
  json: Jason
)
