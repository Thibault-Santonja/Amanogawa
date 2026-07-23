defmodule Mix.Tasks.Amanogawa.Import.Cliopatria do
  @shortdoc "Imports the Cliopatria historical borders GeoJSON file (issue #023)"

  @moduledoc """
  Imports a locally downloaded Cliopatria GeoJSON file into `atlas.
  polities`/`atlas.borders` (source `"cliopatria"`), through
  `Amanogawa.Ingestion.import_cliopatria/1`.

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

  Unzip the archive if needed, then pass the resulting `.geojson` file's
  path as this task's argument. The dataset must never be committed to
  this repository (`.gitignore` a working directory such as `priv/data/`
  if you keep it on disk between runs).

  ## Usage

      mix amanogawa.import.cliopatria PATH

  ## Idempotence

  Safe to re-run: the whole import (purge of the `"cliopatria"` source,
  then reinsertion) happens in a single transaction
  (`Amanogawa.Atlas.replace_borders/2`), so running this task twice on the
  same file leaves the same final row counts, never duplicates.

  ## Exit status

  `0` on success. Non-zero (via `Mix.raise/1`) when `PATH` is missing, not
  given, or not a readable file.
  """

  use Mix.Task

  alias Amanogawa.Ingestion

  @usage "Usage: mix amanogawa.import.cliopatria PATH"

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(argv) do
    Mix.Task.run("app.start")

    path = parse_args!(argv)

    Mix.shell().info("[cliopatria] importing #{path}...")

    {:ok, summary} = Ingestion.import_cliopatria(path)

    print_summary(summary)
  end

  defp parse_args!([path]) do
    if File.regular?(path) do
      path
    else
      Mix.raise("File not found: #{inspect(path)}.\n\n#{@usage}")
    end
  end

  defp parse_args!([]), do: Mix.raise("Missing PATH.\n\n#{@usage}")
  defp parse_args!(many), do: Mix.raise("Too many arguments: #{inspect(many)}.\n\n#{@usage}")

  defp print_summary(summary) do
    Mix.shell().info("""
    [cliopatria] done:
      polities/borders purged (previous \"cliopatria\" rows): #{summary.purged}
      features read:                                          #{summary.total + summary.skipped + summary.invalid_features}
      skipped (non-POLITY rows):                               #{summary.skipped}
      invalid (missing/malformed property):                    #{summary.invalid_features}
      geometries repaired (ST_MakeValid):                      #{summary.repaired}
      borders inserted:                                        #{summary.inserted}
      rejected (empty after repair):                           #{summary.rejected_empty}
    """)
  end
end
