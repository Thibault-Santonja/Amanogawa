defmodule Amanogawa.Accounts.MagicLinkThrottle do
  @moduledoc """
  Double rate limiter for magic link requests (issue #031,
  `.claude/rules/security.md`): `limit` requests per `scale_ms` window
  (default 5 per 15 minutes, `config :amanogawa, __MODULE__`,
  runtime-overridable through `MAGIC_LINK_RATE_LIMIT`,
  `config/runtime.exs`, the same mechanism `AmanogawaWeb.Plugs.RateLimit`
  already uses) PER client IP and, independently, PER normalized email:
  the IP quota bounds one client's own spam, the email quota stops a
  third party from bombarding one inbox from several IPs.

  Deliberately layered on `AmanogawaWeb.RateLimit`, the project's single
  shared ETS-backed Hammer limiter, with its own key prefixes
  (`"magic_link:ip:"`, `"magic_link:email:"`), rather than starting a
  second Hammer instance: `AmanogawaWeb.ExploreLive`'s own selection
  throttle already makes the same choice. Every quota sharing that one
  Hammer table is unaffected by another's: prefixed keys never collide,
  and this module's own tests assert the magic link and public-JSON-
  endpoint quotas are independent.

  Both counters are hit, in a fixed order (IP, then email), on every
  call: a request denied on one counter is still recorded on the other,
  and a denial of either is a denial of the whole request. This module
  is called only after `Amanogawa.Accounts.deliver_magic_link/3` has
  already validated the email's format, so a syntactically invalid
  email never reaches here at all: neither counter is consumed for it
  (a documented choice; the alternative of always consuming the IP
  counter first would be equally defensible, but validation is cheap
  enough that garbage input costs nothing rate-limit-wise here, leaving
  request-volume throttling for garbage input to the web layer's own
  general-purpose limiter in a later issue).
  """

  alias Amanogawa.Accounts.User
  alias AmanogawaWeb.RateLimit

  @default_limit 5
  @default_scale_ms :timer.minutes(15)

  @doc """
  `true` when both the `ip` and the normalized `email` are still under
  quota (and both counters are incremented), `false` when either is
  exhausted (both counters are still incremented, see moduledoc).
  """
  @spec allow?(String.t(), String.t()) :: boolean()
  def allow?(ip, email) do
    normalized_email = User.normalize_email(email)
    {limit, scale_ms} = quota()

    ip_allowed? = allowed?(RateLimit.hit("magic_link:ip:" <> ip, scale_ms, limit))

    email_allowed? =
      allowed?(RateLimit.hit("magic_link:email:" <> normalized_email, scale_ms, limit))

    ip_allowed? and email_allowed?
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
