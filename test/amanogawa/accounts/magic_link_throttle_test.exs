defmodule Amanogawa.Accounts.MagicLinkThrottleTest do
  use ExUnit.Case, async: false

  alias Amanogawa.Accounts.MagicLinkThrottle

  setup do
    original = Application.get_env(:amanogawa, MagicLinkThrottle, [])

    Application.put_env(
      :amanogawa,
      MagicLinkThrottle,
      Keyword.merge(original, limit: 5, scale_ms: :timer.hours(24))
    )

    on_exit(fn -> Application.put_env(:amanogawa, MagicLinkThrottle, original) end)
  end

  test "the IP quota allows up to the limit, then denies, independently of email" do
    ip = unique_ip()

    for n <- 1..5 do
      assert MagicLinkThrottle.allow?(ip, "user-#{n}@example.com")
    end

    refute MagicLinkThrottle.allow?(ip, "user-6@example.com")
  end

  test "the email quota allows up to the limit (any casing), then denies, independently of IP" do
    email = "Person@Example.com"

    for _n <- 1..5 do
      assert MagicLinkThrottle.allow?(unique_ip(), String.upcase(email))
    end

    refute MagicLinkThrottle.allow?(unique_ip(), String.downcase(email))
  end

  test "a denial on either counter denies the whole request" do
    shared_ip = unique_ip()
    shared_email = "shared@example.com"

    for _n <- 1..5, do: MagicLinkThrottle.allow?(shared_ip, shared_email)

    # IP already exhausted; a brand new email still gets denied.
    refute MagicLinkThrottle.allow?(shared_ip, unique_email())
    # Email already exhausted; a brand new IP still gets denied.
    refute MagicLinkThrottle.allow?(unique_ip(), shared_email)
  end

  describe "integration: independence from the public JSON endpoint quota" do
    test "exhausting the magic link IP quota does not touch AmanogawaWeb.Plugs.RateLimit's own IP-keyed counter" do
      ip = unique_ip()

      for _n <- 1..5, do: MagicLinkThrottle.allow?(ip, unique_email())
      refute MagicLinkThrottle.allow?(ip, unique_email())

      # AmanogawaWeb.Plugs.RateLimit hits the bare IP as its key (no
      # prefix, see `client_key/1`): distinct from this module's
      # "magic_link:ip:" prefix, so it must still have its full quota.
      assert {:allow, 1} = AmanogawaWeb.RateLimit.hit(ip, :timer.minutes(1), 120)
    end

    test "exhausting the public JSON endpoint quota does not touch the magic link IP counter" do
      ip = unique_ip()

      for _n <- 1..120, do: AmanogawaWeb.RateLimit.hit(ip, :timer.minutes(1), 120)
      assert {:deny, _} = AmanogawaWeb.RateLimit.hit(ip, :timer.minutes(1), 120)

      assert MagicLinkThrottle.allow?(ip, unique_email())
    end
  end

  defp unique_ip, do: "10.0.0.#{System.unique_integer([:positive, :monotonic])}"
  defp unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"
end
