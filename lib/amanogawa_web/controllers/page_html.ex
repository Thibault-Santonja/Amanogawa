defmodule AmanogawaWeb.PageHTML do
  @moduledoc """
  Templates for `AmanogawaWeb.PageController` (issue #027): Sources/About,
  legal notice, privacy policy, and (issue #038) the public moderation
  rules and statistics.
  """

  use AmanogawaWeb, :html

  embed_templates "page_html/*"

  @doc """
  A section heading and body used by every static page, keeping the same
  spacing and type scale everywhere content is added (utility classes
  only, per `assets/css/app.css`'s own convention, no bespoke CSS class).
  """
  attr :title, :string, required: true
  slot :inner_block, required: true

  def section(assigns) do
    ~H"""
    <section class="mt-8">
      <h2 class="mb-2 text-lg font-semibold text-text">{@title}</h2>
      <div class="space-y-3 leading-relaxed text-text">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  An external link styled consistently across the static pages, always
  `rel="noopener noreferrer"` (issue #027 test: every external link on
  these pages carries it) since every link here leaves the site (source
  repositories, license texts, the host's own site).
  """
  attr :href, :string, required: true
  attr :rest, :global
  slot :inner_block, required: true

  def external_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener noreferrer"
      class="underline hover:text-accent"
      {@rest}
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  @doc """
  One factual number tile on `/moderation` (issue #038): a status total,
  never a ranking or a trend arrow (F08 overview's anti-dark-patterns
  principle, `/moderation`'s own moduledoc note).
  """
  attr :label, :string, required: true
  attr :value, :integer, required: true

  def stat_tile(assigns) do
    ~H"""
    <div class="rounded-md border border-border bg-surface p-3 text-center">
      <p class="text-2xl font-semibold text-text">{@value}</p>
      <p class="text-xs text-text-muted">{@label}</p>
    </div>
    """
  end

  @doc "Translated label for an `Amanogawa.Contributions.Override` status, `/moderation`'s stat tiles."
  @spec status_label(atom()) :: String.t()
  def status_label(:pending), do: gettext("En attente")
  def status_label(:accepted), do: gettext("Acceptées")
  def status_label(:rejected), do: gettext("Rejetées")
  def status_label(:appealed), do: gettext("En appel")
  def status_label(:superseded), do: gettext("Remplacées")

  @doc """
  Renders `Amanogawa.Contributions.public_stats/0`'s `median_decision_hours`
  as a sentence: `nil` (no decision yet) is an honest "not applicable",
  never a `0` (F08 overview / issue #038: never overstate what the data
  actually shows).
  """
  @spec median_decision_label(float() | nil) :: String.t()
  def median_decision_label(nil), do: gettext("aucune décision pour le moment")

  def median_decision_label(hours) do
    gettext("%{hours} heures", hours: Float.round(hours * 1.0, 1))
  end
end
