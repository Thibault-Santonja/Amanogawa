defmodule AmanogawaWeb.RateLimit do
  @moduledoc """
  Hammer-backed rate limiter (ETS backend, fixed window), the mechanism
  behind `AmanogawaWeb.Plugs.RateLimit`.

  Per `.claude/rules/security.md`, every public JSON endpoint is rate
  limited per client IP; this module is the single shared limiter all such
  plugs hit against, so quota is tracked in one ETS table regardless of how
  many endpoints end up using it.

  Started once, as a permanent child of `Amanogawa.Application`. The quota
  itself (`:limit` requests per `:scale_ms` window) is not configured here:
  it lives in `config :amanogawa, AmanogawaWeb.RateLimit` and is read by the
  plug at request time, so it can be tuned per environment (see
  `config/runtime.exs`) without touching this module.
  """

  use Hammer, backend: :ets
end
