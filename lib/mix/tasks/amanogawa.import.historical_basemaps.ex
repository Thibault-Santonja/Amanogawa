defmodule Mix.Tasks.Amanogawa.Import.HistoricalBasemaps do
  @shortdoc "Imports historical-basemaps prehistoric border tranches (issue #024)"

  @moduledoc """
  Imports the locally downloaded historical-basemaps GeoJSON tranche files
  under a directory into `atlas.polities`/`atlas.borders` (source
  `"historical_basemaps"`), through
  `Amanogawa.Ingestion.import_historical_basemaps/2`.

  ## Manual download (never committed to the repository)

    * Source: `aourednik/historical-basemaps`
      (https://github.com/aourednik/historical-basemaps), directory
      `geojson/`.
    * License: GPL-3.0. Compatible with this project's AGPL-3.0 (ADR
      0004), but attribution is still required wherever the imported
      borders are displayed (map credits, #025; Sources page, F06 #027):
      "historical-basemaps, A. Ourednik, GPL-3.0".

  ### Pinning the imported revision

  The repository has no tagged releases: to make an import reproducible
  and auditable, record the exact commit the files came from. After
  cloning, run:

      git -C historical-basemaps rev-parse HEAD

  and note the printed commit hash alongside the import date (for example
  in the ops log or the Sources page draft, F06 #027). Re-importing later
  from the same commit (`git -C historical-basemaps checkout <hash>`)
  reproduces the same rows.

  Clone the repository (`git clone https://github.com/aourednik/
  historical-basemaps`) or download only the `geojson/world_bc*.geojson`
  files you need, into a local directory (never committed: `priv/data/`
  is `.gitignore`d as the recommended working directory). Only files
  matching the `world[_bc]<year>.geojson` naming convention and dated
  strictly before -3400 are imported (ADR 0004, issue #024's junction
  with Cliopatria); every other file in the directory is reported, never
  imported.

  ## Usage

      mix amanogawa.import.historical_basemaps PATH [--force]

  `PATH`: the directory containing the tranche `.geojson` files (for
  example the repository's own `geojson/` directory after cloning).

  `--force`: bypasses the anti-wipe guard. Without it, an import that
  purges existing `"historical_basemaps"` rows and inserts none (wrong
  directory, wholly corrupted files) aborts and rolls back, leaving the
  previous data untouched. Pass `--force` only to deliberately empty the
  source.

  ## Idempotence

  Safe to re-run: every tranche's rows are imported in a single
  purge-then-reinsert transaction scoped to the `"historical_basemaps"`
  source (`Amanogawa.Atlas.replace_borders/3`), so Cliopatria's own rows
  are never touched and re-running this task on the same directory leaves
  the same final row counts, never duplicates.

  ## Exit status

  `0` on success. Non-zero (via `Mix.raise/1`) when `PATH` is missing, not
  given, or not a readable directory; when a tranche file is not a
  readable `FeatureCollection` (scanner or filesystem error); or when the
  anti-wipe guard refuses the import (see `--force` above).
  """

  use Mix.Task

  alias Amanogawa.Ingestion

  @usage "Usage: mix amanogawa.import.historical_basemaps PATH [--force]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {path, force} = parse_args!(argv)

    Mix.shell().info("[historical_basemaps] importing tranches from #{path}...")

    case import_with_clear_errors(path, force) do
      {:ok, summary} ->
        print_summary(summary)

      {:error, {:would_wipe_source, source, purged}} ->
        Mix.raise(
          "Import aborted and rolled back: it would have purged #{purged} existing " <>
            "#{inspect(source)} border(s) without inserting any (every feature was " <>
            "rejected: wrong directory or corrupted files?). The previous data is " <>
            "untouched. Pass --force to deliberately empty the source."
        )

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  # A scanner error (a tranche that is not a FeatureCollection, a
  # truncated file) or a filesystem error raises from inside the lazy
  # streams: surfaced as a clean `Mix.raise` (non-zero exit status)
  # instead of a crash dump.
  defp import_with_clear_errors(path, force) do
    Ingestion.import_historical_basemaps(path, force: force)
  rescue
    error in [RuntimeError, File.Error] ->
      Mix.raise("Import failed while reading #{inspect(path)}: #{Exception.message(error)}")
  end

  defp parse_args!(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [force: :boolean])

    case args do
      [path] ->
        if File.dir?(path) do
          {path, Keyword.get(opts, :force, false)}
        else
          Mix.raise("Directory not found: #{inspect(path)}.\n\n#{@usage}")
        end

      [] ->
        Mix.raise("Missing PATH.\n\n#{@usage}")

      many ->
        Mix.raise("Too many arguments: #{inspect(many)}.\n\n#{@usage}")
    end
  end

  defp print_summary(summary) do
    Mix.shell().info("""
    [historical_basemaps] done:
      borders purged (previous \"historical_basemaps\" rows): #{summary.purged}
      orphan polities purged:                                #{summary.purged_polities}
      tranches imported (years):                             #{inspect(summary.tranches_imported)}
      tranches excluded (>= -3400, never imported):          #{inspect(summary.tranches_excluded)}
      unrecognized files (skipped):                          #{inspect(summary.unrecognized_files)}
      features skipped (no NAME):                            #{summary.skipped}
      invalid (missing/malformed property):                  #{summary.invalid_features}
      geometries repaired (ST_MakeValid):                    #{summary.repaired}
      borders inserted:                                      #{summary.inserted}
      rejected (empty after repair):                         #{summary.rejected_empty}
    """)
  end
end
