defmodule Mix.Tasks.Amanogawa.Import.HistoricalBasemaps do
  @shortdoc "Imports historical-basemaps prehistoric border tranches (issue #024)"

  @moduledoc """
  Imports the locally downloaded historical-basemaps GeoJSON tranche files
  under a directory into `atlas.polities`/`atlas.borders` (source
  `"historical_basemaps"`), through
  `Amanogawa.Ingestion.import_historical_basemaps/1`.

  ## Manual download (never committed to the repository)

    * Source: `aourednik/historical-basemaps`
      (https://github.com/aourednik/historical-basemaps), directory
      `geojson/`.
    * License: GPL-3.0. Compatible with this project's AGPL-3.0 (ADR
      0004), but attribution is still required wherever the imported
      borders are displayed (map credits, #025; Sources page, F06 #027):
      "historical-basemaps, A. Ourednik, GPL-3.0".

  Clone the repository (`git clone https://github.com/aourednik/
  historical-basemaps`) or download only the `geojson/world_bc*.geojson`
  files you need, into a local directory (never committed: `.gitignore`
  it if you keep it on disk between runs). Only files matching the
  `world[_bc]<year>.geojson` naming convention and dated strictly before
  -3400 are imported (ADR 0004, issue #024's junction with Cliopatria);
  every other file in the directory is reported, never imported.

  ## Usage

      mix amanogawa.import.historical_basemaps PATH

  `PATH`: the directory containing the tranche `.geojson` files (for
  example the repository's own `geojson/` directory after cloning).

  ## Idempotence

  Safe to re-run: every tranche's rows are imported in a single
  purge-then-reinsert transaction scoped to the `"historical_basemaps"`
  source (`Amanogawa.Atlas.replace_borders/2`), so Cliopatria's own rows
  are never touched and re-running this task on the same directory leaves
  the same final row counts, never duplicates.

  ## Exit status

  `0` on success. Non-zero (via `Mix.raise/1`) when `PATH` is missing, not
  given, or not a readable directory.
  """

  use Mix.Task

  alias Amanogawa.Ingestion

  @usage "Usage: mix amanogawa.import.historical_basemaps PATH"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    path = parse_args!(argv)

    Mix.shell().info("[historical_basemaps] importing tranches from #{path}...")

    {:ok, summary} = Ingestion.import_historical_basemaps(path)

    print_summary(summary)
  end

  defp parse_args!([path]) do
    if File.dir?(path) do
      path
    else
      Mix.raise("Directory not found: #{inspect(path)}.\n\n#{@usage}")
    end
  end

  defp parse_args!([]), do: Mix.raise("Missing PATH.\n\n#{@usage}")
  defp parse_args!(many), do: Mix.raise("Too many arguments: #{inspect(many)}.\n\n#{@usage}")

  defp print_summary(summary) do
    Mix.shell().info("""
    [historical_basemaps] done:
      polities/borders purged (previous \"historical_basemaps\" rows): #{summary.purged}
      tranches imported (years):                                       #{inspect(summary.tranches_imported)}
      tranches excluded (>= -3400, never imported):                    #{inspect(summary.tranches_excluded)}
      unrecognized files (skipped):                                    #{inspect(summary.unrecognized_files)}
      features skipped (no NAME):                                      #{summary.skipped}
      invalid (missing/malformed property):                            #{summary.invalid_features}
      geometries repaired (ST_MakeValid):                              #{summary.repaired}
      borders inserted:                                                #{summary.inserted}
      rejected (empty after repair):                                   #{summary.rejected_empty}
    """)
  end
end
