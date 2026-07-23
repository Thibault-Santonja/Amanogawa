defmodule AmanogawaWeb.Components.TimeLegend do
  @moduledoc """
  The temporal gradient legend (issue #022): a small gradient bar with the
  current window's bounds labeled on either side, making explicit the
  blue-to-red color code applied to the map markers
  (`assets/js/hooks/map_hook.js`) and the timeline window
  (`assets/js/hooks/timeline.js`).

  The gradient itself is a plain CSS `linear-gradient` reading the exact
  same `--time-start-color`/`--time-end-color` custom properties
  (`assets/css/app.css`, `.claude/rules/tailwind.md`'s single source of
  truth) the other two renderings resolve through JS: no color is
  hardcoded here, and no interpolation space is specified (the CSS
  default, sRGB, matches the other two engines by construction, per
  `assets/js/lib/time_gradient.js`'s own documented convention).

  Rendered inside `AmanogawaWeb.ExploreLive`'s template, outside the
  `TimelineHook`'s `phx-update="ignore"` subtree: an ordinary function
  component, it re-renders on every `from`/`to` assign change like any
  other part of the page, no JS wiring of its own.
  """

  use AmanogawaWeb, :html

  alias Amanogawa.Atlas
  alias AmanogawaWeb.TimelineI18n

  attr :from, :integer, required: true
  attr :to, :integer, required: true

  def time_legend(assigns) do
    ~H"""
    <div
      id="time-legend"
      class="pointer-events-none absolute right-3 top-2 flex items-center gap-2 rounded-full border border-border bg-surface/90 px-2 py-1 text-xs text-text-muted shadow-sm"
    >
      <span>{format_bound(@from, @to)}</span>
      <span
        class="h-1.5 w-14 shrink-0 rounded-full"
        style="background-image: linear-gradient(to right, var(--time-start-color), var(--time-end-color));"
        aria-hidden="true"
      ></span>
      <span>{format_bound(@to, @from)}</span>
    </div>
    """
  end

  # Each bound is labeled at the granularity its distance to the *other*
  # bound suggests (`Amanogawa.Atlas.format_axis_year/3`, issue #020's
  # formatter, localized through `AmanogawaWeb.TimelineI18n`'s templates):
  # a narrow window reads its exact years, a wide one reads centuries or
  # millennia BP, mirroring how the axis itself scales its own tick labels
  # with the window's span.
  defp format_bound(year, other_year) do
    step = max(abs(other_year - year), 1)
    Atlas.format_axis_year(year, step, TimelineI18n.axis_templates())
  end
end
