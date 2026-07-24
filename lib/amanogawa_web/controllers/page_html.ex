defmodule AmanogawaWeb.PageHTML do
  @moduledoc """
  Templates for `AmanogawaWeb.PageController` (issue #027): Sources/About,
  legal notice, privacy policy.
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
end
