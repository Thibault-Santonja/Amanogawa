defmodule Amanogawa.Atlas.PolityColor do
  @moduledoc """
  Stable color per polity name (issue #025): the same entity always gets
  the same hue, whichever year's `GET /api/borders` response it appears
  in, so a viewer's eye can follow one political entity across the
  timeline by color alone (F05 user story).

  Pure and deterministic: `hue_for/1` hashes `name` with SHA-256 (not
  `:erlang.phash2/1`, whose exact output is only guaranteed stable within
  one OTP major release, per its own documentation; a border's color must
  never shift after an unrelated runtime upgrade) and folds the first 32
  bits of the digest into `[0, 360)`. Saturation and lightness are fixed
  (`#{inspect(__MODULE__)}` never varies them), so only the hue carries
  identity.

  The result is a plain `hsl()` string, a syntax MapLibre's color parser
  accepts natively (unlike the `oklch()` CSS custom properties resolved
  through `maplibreColor` in `assets/js/hooks/map_hook.js`: this value
  never touches a CSS custom property, it is computed here and read
  straight off `properties.color` by the style's `["get", "color"]`
  expression, so no such resolution step applies to it).

  ## Examples

      iex> Amanogawa.Atlas.PolityColor.for_name("Roman Empire")
      "hsl(346, 45%, 55%)"

  """

  # Fixed so only the hue (identity) varies: mid saturation and lightness
  # keep every polity's fill legible (not washed out, not neon) at the
  # ~0.25 fill-opacity the map layer renders it at
  # (`assets/js/map/border_layers.js`), regardless of hue.
  @saturation 45
  @lightness 55

  @doc """
  The stable `hsl(h, #{@saturation}%, #{@lightness}%)` color for `name`.
  """
  @spec for_name(String.t()) :: String.t()
  def for_name(name) when is_binary(name) do
    "hsl(#{hue_for(name)}, #{@saturation}%, #{@lightness}%)"
  end

  @doc """
  The stable hue (an integer in `[0, 360)`) for `name`, deterministic
  across calls, processes, and nodes.
  """
  @spec hue_for(String.t()) :: 0..359
  def hue_for(name) when is_binary(name) do
    <<hash_int::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, name)
    rem(hash_int, 360)
  end
end
