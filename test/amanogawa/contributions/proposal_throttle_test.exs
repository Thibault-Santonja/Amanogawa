defmodule Amanogawa.Contributions.ProposalThrottleTest do
  use ExUnit.Case, async: false

  alias Amanogawa.Contributions.ProposalThrottle

  setup do
    original = Application.get_env(:amanogawa, ProposalThrottle, [])

    Application.put_env(
      :amanogawa,
      ProposalThrottle,
      Keyword.merge(original, limit: 5, scale_ms: :timer.hours(24))
    )

    on_exit(fn -> Application.put_env(:amanogawa, ProposalThrottle, original) end)
  end

  test "the author quota allows up to the limit, then denies, independently of IP" do
    author_id = Ecto.UUID.generate()

    for _n <- 1..5 do
      assert ProposalThrottle.allow?(author_id, unique_ip())
    end

    refute ProposalThrottle.allow?(author_id, unique_ip())
  end

  test "the IP quota allows up to the limit, then denies, independently of author" do
    ip = unique_ip()

    for _n <- 1..5 do
      assert ProposalThrottle.allow?(Ecto.UUID.generate(), ip)
    end

    refute ProposalThrottle.allow?(Ecto.UUID.generate(), ip)
  end

  test "a denial on either counter denies the whole request" do
    shared_author_id = Ecto.UUID.generate()
    shared_ip = unique_ip()

    for _n <- 1..5, do: ProposalThrottle.allow?(shared_author_id, shared_ip)

    # Author already exhausted; a brand new IP still gets denied.
    refute ProposalThrottle.allow?(shared_author_id, unique_ip())
    # IP already exhausted; a brand new author still gets denied.
    refute ProposalThrottle.allow?(Ecto.UUID.generate(), shared_ip)
  end

  describe "integration: independence from the magic link and public JSON quotas" do
    test "exhausting the proposal IP quota does not touch AmanogawaWeb.Plugs.RateLimit's own IP-keyed counter" do
      ip = unique_ip()

      for _n <- 1..5, do: ProposalThrottle.allow?(Ecto.UUID.generate(), ip)
      refute ProposalThrottle.allow?(Ecto.UUID.generate(), ip)

      assert {:allow, 1} = AmanogawaWeb.RateLimit.hit(ip, :timer.minutes(1), 120)
    end
  end

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    "10.#{rem(div(n, 65_536), 256)}.#{rem(div(n, 256), 256)}.#{rem(n, 256)}"
  end
end
