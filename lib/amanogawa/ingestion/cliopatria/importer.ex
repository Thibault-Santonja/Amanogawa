defmodule Amanogawa.Ingestion.Cliopatria.Importer do
  @moduledoc """
  Entry point of the Cliopatria import (issue #023): a thin wrapper over
  `Amanogawa.Ingestion.Borders.Importer.import/3` with the source name
  (`"cliopatria"`) and parser (`Amanogawa.Ingestion.Cliopatria.Parser`)
  fixed, called by `Mix.Tasks.Amanogawa.Import.Cliopatria`.
  """

  alias Amanogawa.Ingestion.Borders.Importer
  alias Amanogawa.Ingestion.Cliopatria.Parser

  @source "cliopatria"

  @doc "The `atlas.polities`/`atlas.borders` source tag used for every Cliopatria row."
  @spec source() :: String.t()
  def source, do: @source

  @doc """
  Imports the Cliopatria GeoJSON file at `path`. See `Amanogawa.Ingestion.
  Borders.Importer.import/4` for the returned summary shape and the
  `:force` option (anti-wipe guard).
  """
  @spec import(Path.t(), keyword()) :: {:ok, Importer.summary()} | {:error, term()}
  def import(path, opts \\ []) do
    Importer.import(path, @source, &Parser.parse_feature/1, opts)
  end
end
