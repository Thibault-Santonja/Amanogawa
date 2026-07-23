defmodule AmanogawaWeb.TimelineI18nTest do
  use ExUnit.Case, async: true

  alias Amanogawa.Atlas
  alias AmanogawaWeb.TimelineI18n

  describe "axis_templates/0" do
    test "the default (fr) locale serves the French source templates, placeholders intact" do
      templates = TimelineI18n.axis_templates()

      assert templates.ka_bp =~ "%{ka}"
      assert templates.century =~ "%{century}"
      assert templates.bce =~ "%{text}"

      assert templates == %{
               ka_bp: "%{ka} ka BP",
               century: "%{century}e s.",
               bce: "%{text} av. J.-C."
             }
    end

    test "the en locale serves translated templates, placeholders intact" do
      templates = Gettext.with_locale(AmanogawaWeb.Gettext, "en", &TimelineI18n.axis_templates/0)

      assert templates.ka_bp =~ "%{ka}"
      assert templates.century =~ "%{century}"
      assert templates.bce =~ "%{text}"

      # Rendered through the shared formatter, the English templates
      # produce English labels (the exact strings live in the .po file;
      # what matters here is that the placeholder substitution works end
      # to end).
      assert Atlas.format_axis_year(-489, 1, templates) == "490 BCE"
      assert Atlas.format_axis_year(1100, 100, templates) == "XIIth c."
    end
  end

  describe "window handle labels" do
    test "fr (default) and en both serve non-empty, distinct start/end labels" do
      assert TimelineI18n.window_start_label() == "Début de la fenêtre"
      assert TimelineI18n.window_end_label() == "Fin de la fenêtre"

      {start_en, end_en} =
        Gettext.with_locale(AmanogawaWeb.Gettext, "en", fn ->
          {TimelineI18n.window_start_label(), TimelineI18n.window_end_label()}
        end)

      assert start_en == "Start of the window"
      assert end_en == "End of the window"
    end
  end
end
