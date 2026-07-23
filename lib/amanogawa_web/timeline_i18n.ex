defmodule AmanogawaWeb.TimelineI18n do
  @moduledoc """
  The translated labels of the timeline strip (F04 quality finding m6),
  gathered in one place under the Gettext domain `"timeline"`:

    * the axis-label templates `Amanogawa.Atlas.TimeScale.Format` renders
      through (`axis_templates/0`), consumed server-side by
      `AmanogawaWeb.Components.TimeLegend` and shipped to the client hook
      through `data-i18n-*` attributes rendered by
      `AmanogawaWeb.ExploreLive` (the same pattern the map hover card
      already uses: labels are translated server-side, JS only ever reads
      them off the DOM, never hardcodes a language);
    * the ARIA labels of the interactive window's two drag handles
      (`window_start_label/0` / `window_end_label/0`), served the same
      way.

  Template placeholders (`%{ka}`, `%{century}`, `%{text}`) must survive
  translation untouched: the client substitutes them itself. They are
  therefore passed through `dgettext/3` bound to their own literal marker
  (`ka: "%{ka}"`), which re-inserts the marker verbatim into the
  translated string instead of triggering the missing-binding fallback.
  """

  use Gettext, backend: AmanogawaWeb.Gettext

  alias Amanogawa.Atlas.TimeScale.Format

  @doc """
  The axis-label templates in the current locale, shaped for
  `Amanogawa.Atlas.TimeScale.Format.format_axis_year/3`.
  """
  @spec axis_templates() :: Format.templates()
  def axis_templates do
    %{
      ka_bp: dgettext("timeline", "%{ka} ka BP", ka: "%{ka}"),
      century: dgettext("timeline", "%{century}e s.", century: "%{century}"),
      bce: dgettext("timeline", "%{text} av. J.-C.", text: "%{text}")
    }
  end

  @doc "ARIA label of the window's left (start) drag handle."
  @spec window_start_label() :: String.t()
  def window_start_label, do: dgettext("timeline", "Début de la fenêtre")

  @doc "ARIA label of the window's right (end) drag handle."
  @spec window_end_label() :: String.t()
  def window_end_label, do: dgettext("timeline", "Fin de la fenêtre")
end
