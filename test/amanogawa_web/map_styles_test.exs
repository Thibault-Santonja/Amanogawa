defmodule AmanogawaWeb.MapStylesTest do
  # Guards the vendored MapLibre styles (assets/vendor/map-styles/) against
  # regressions during manual updates: structure, allowed remote origins
  # (kept coherent with the Content-Security-Policy), and ODbL attribution.
  use ExUnit.Case, async: true

  alias AmanogawaWeb.Plugs.ContentSecurityPolicy

  @styles_dir Path.expand("../../assets/vendor/map-styles", __DIR__)
  @style_files ["light.json", "dark.json"]

  defp decode!(file) do
    @styles_dir
    |> Path.join(file)
    |> File.read!()
    |> Jason.decode!()
  end

  defp remote_urls(style) do
    source_urls =
      style
      |> Map.fetch!("sources")
      |> Map.values()
      |> Enum.flat_map(fn source ->
        List.wrap(source["url"]) ++ List.wrap(source["tiles"])
      end)

    source_urls ++ List.wrap(style["glyphs"]) ++ List.wrap(style["sprite"])
  end

  for file <- @style_files do
    describe "#{file}" do
      test "has the minimal MapLibre style structure" do
        style = decode!(unquote(file))

        assert style["version"] == 8
        assert map_size(style["sources"]) > 0
        assert is_list(style["layers"]) and style["layers"] != []
        assert is_binary(style["glyphs"]) and style["glyphs"] != ""
      end

      test "only references remote URLs on the CSP tiles origin" do
        urls = unquote(file) |> decode!() |> remote_urls()

        assert urls != []

        for url <- urls do
          assert String.starts_with?(url, ContentSecurityPolicy.tiles_origin()),
                 "#{url} is outside the origin allowed by the CSP"
        end
      end

      test "declares a non-empty attribution crediting OpenStreetMap" do
        attributions =
          unquote(file)
          |> decode!()
          |> Map.fetch!("sources")
          |> Map.values()
          |> Enum.flat_map(&List.wrap(&1["attribution"]))

        assert Enum.any?(attributions, &(&1 =~ "OpenStreetMap"))
      end
    end
  end
end
