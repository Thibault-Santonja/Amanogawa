defmodule Mix.Tasks.Amanogawa.Import.Cliopatria do
  @shortdoc "Imports the Cliopatria historical borders GeoJSON file (issue #023)"

  @moduledoc """
  Imports a locally downloaded Cliopatria GeoJSON file into `atlas.
  polities`/`atlas.borders` (source `"cliopatria"`), through
  `Amanogawa.Ingestion.import_cliopatria/2`.

  ## Manual download (never committed to the repository)

  Cliopatria is not fetched automatically: download it by hand before
  running this task.

    * Source: Seshat-Global-History-Databank/cliopatria, Zenodo record
      14714684, release v0.1.3.
    * URL: https://zenodo.org/records/14714684 (download `cliopatria.
      geojson.zip`, or the `.geojson` directly if offered).
    * Size: approximately 307MB uncompressed.
    * License: CC BY 4.0. Attribution is required wherever the imported
      borders are displayed (map credits, #025; Sources page, F06 #027):
      "Cliopatria, Seshat Global History Databank, CC BY 4.0".

  ### Checksum verification

  Zenodo displays an md5 checksum next to each file of the record
  (https://zenodo.org/records/14714684, "Files" section; also available
  through the record API, https://zenodo.org/api/records/14714684, in
  `files[].checksum`). After downloading, compute the local checksum and
  compare it to the value shown on that page before importing:

      md5 cliopatria.geojson.zip        # macOS
      md5sum cliopatria.geojson.zip     # Linux

  Do not trust a checksum value copied from anywhere else (including this
  file, which deliberately records the procedure, not a value): the
  record page is the authority.

  Unzip the archive if needed, then pass the resulting `.geojson` file's
  path as this task's argument. The dataset must never be committed to
  this repository (`priv/data/` is `.gitignore`d as the recommended
  working directory for keeping it on disk between runs).

  ## Usage

      mix amanogawa.import.cliopatria PATH [--force]

  `--force`: bypasses the anti-wipe guard. Without it, an import that
  purges existing `"cliopatria"` rows and inserts none (a wrong or wholly
  corrupted file: 100% of features rejected) aborts and rolls back,
  leaving the previous data untouched. Pass `--force` only to
  deliberately empty the source.

  ## Idempotence

  Safe to re-run: the whole import (purge of the `"cliopatria"` source,
  then reinsertion) happens in a single transaction
  (`Amanogawa.Atlas.replace_borders/3`), so running this task twice on the
  same file leaves the same final row counts, never duplicates.

  ## Boundary-year check

  After a successful import, the task counts pairs of rows of the same
  polity where one polygon's `ToYear` equals the next one's `FromYear`
  (`Amanogawa.Atlas.count_boundary_year_overlaps/1`). Under this
  project's inclusive `[from_year, to_year]` convention, such a pair
  double-covers its boundary year: `GET /api/borders?year=` for that year
  returns both polygons. A non-zero count is reported as a warning (never
  a failure): it means the source uses touching intervals, and a
  normalization of the interval convention (for example importing
  `ToYear - 1`) should be considered before relying on single-year
  queries around those boundary years.

  ## Exit status

  `0` on success. Non-zero (via `Mix.raise/1`) when `PATH` is missing, not
  given, or not a readable file; when the file is not a readable
  `FeatureCollection` (scanner or filesystem error); or when the
  anti-wipe guard refuses the import (see `--force` above).
  """

  use Mix.Task

  alias Amanogawa.Atlas
  alias Amanogawa.Ingestion

  @usage "Usage: mix amanogawa.import.cliopatria PATH [--force]"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    {path, force} = parse_args!(argv)

    Mix.shell().info("[cliopatria] importing #{path}...")

    case import_with_clear_errors(path, force) do
      {:ok, summary} ->
        print_summary(summary)
        check_boundary_years()

      {:error, {:would_wipe_source, source, purged}} ->
        Mix.raise(
          "Import aborted and rolled back: it would have purged #{purged} existing " <>
            "#{inspect(source)} border(s) without inserting any (every feature was " <>
            "rejected: wrong or corrupted file?). The previous data is untouched. " <>
            "Pass --force to deliberately empty the source."
        )

      {:error, reason} ->
        Mix.raise("Import failed: #{inspect(reason)}")
    end
  end

  # A scanner error (not a FeatureCollection, truncated file) or a
  # filesystem error raises from inside the lazy stream: surfaced as a
  # clean `Mix.raise` (non-zero exit status) instead of a crash dump.
  defp import_with_clear_errors(path, force) do
    Ingestion.import_cliopatria(path, force: force)
  rescue
    error in [RuntimeError, File.Error] ->
      Mix.raise("Import failed while reading #{inspect(path)}: #{Exception.message(error)}")
  end

  defp parse_args!(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: [force: :boolean])

    case args do
      [path] ->
        if File.regular?(path) do
          {path, Keyword.get(opts, :force, false)}
        else
          Mix.raise("File not found: #{inspect(path)}.\n\n#{@usage}")
        end

      [] ->
        Mix.raise("Missing PATH.\n\n#{@usage}")

      many ->
        Mix.raise("Too many arguments: #{inspect(many)}.\n\n#{@usage}")
    end
  end

  defp print_summary(summary) do
    Mix.shell().info("""
    [cliopatria] done:
      borders purged (previous \"cliopatria\" rows): #{summary.purged}
      orphan polities purged:                       #{summary.purged_polities}
      features read:                                #{summary.total + summary.skipped + summary.invalid_features}
      skipped (non-POLITY rows):                    #{summary.skipped}
      invalid (missing/malformed property):         #{summary.invalid_features}
      geometries repaired (ST_MakeValid):           #{summary.repaired}
      borders inserted:                             #{summary.inserted}
      rejected (empty after repair):                #{summary.rejected_empty}
    """)
  end

  # See the moduledoc's "Boundary-year check" section: a warning, never a
  # failure.
  defp check_boundary_years do
    case Atlas.count_boundary_year_overlaps("cliopatria") do
      0 ->
        :ok

      count ->
        Mix.shell().info(
          "[cliopatria] warning: #{count} pair(s) of polygons of the same polity share a " <>
            "boundary year (one row's ToYear equals the next row's FromYear). Under the " <>
            "inclusive [from_year, to_year] convention both polygons are active at that " <>
            "year; consider normalizing the interval convention (see the task moduledoc)."
        )
    end
  end
end
