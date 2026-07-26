defmodule Amanogawa.Contributions.ProposalThrottle do
  @moduledoc """
  Double rate limiter for contribution proposals (issue #036,
  `.claude/rules/security.md`): `limit` proposals per `scale_ms` window
  (default 10 per hour, `config :amanogawa, __MODULE__`) PER author id
  and, independently, PER client IP: the author quota bounds one account's
  own volume, the IP quota stops a single client from spamming through
  several accounts.

  Calqued on `Amanogawa.Accounts.MagicLinkThrottle`: layered on
  `AmanogawaWeb.RateLimit`, the project's single shared ETS-backed Hammer
  limiter, with its own key prefixes (`"contribution:user:"`,
  `"contribution:ip:"`), rather than starting a second Hammer instance.
  Prefixed keys never collide with another module's own quota sharing the
  same table.

  Both counters are hit, in a fixed order (user, then IP), on every call:
  a request denied on one counter is still recorded on the other, and a
  denial of either is a denial of the whole request (same contract as
  `MagicLinkThrottle.allow?/2`).

  Checked from INSIDE `Amanogawa.Contributions.propose/3`, before any
  database write: the quota is a domain invariant, not a UI nicety, so a
  future proposal entry point (a public API, a different LiveView) cannot
  bypass it by simply not calling this module first (F08 overview / issue
  #036's own point d'attention: "le quota se vérifie dans le domaine...
  une future API ne doit pas pouvoir le contourner").
  """

  alias AmanogawaWeb.RateLimit

  @default_limit 10
  @default_scale_ms :timer.hours(1)

  @doc """
  `true` when both `author_id` and `ip` are still under quota (both
  counters are incremented), `false` when either is exhausted (both
  counters are still incremented, see moduledoc).
  """
  @spec allow?(Ecto.UUID.t(), String.t()) :: boolean()
  def allow?(author_id, ip) do
    {limit, scale_ms} = quota()

    user_allowed? = allowed?(RateLimit.hit("contribution:user:" <> author_id, scale_ms, limit))
    ip_allowed? = allowed?(RateLimit.hit("contribution:ip:" <> ip, scale_ms, limit))

    user_allowed? and ip_allowed?
  end

  defp allowed?({:allow, _count}), do: true
  defp allowed?({:deny, _retry_after_ms}), do: false

  defp quota do
    config = Application.get_env(:amanogawa, __MODULE__, [])

    limit = Keyword.get(config, :limit, @default_limit)
    scale_ms = Keyword.get(config, :scale_ms, @default_scale_ms)

    {limit, scale_ms}
  end
end
