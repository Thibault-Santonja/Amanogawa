defmodule Amanogawa.AccountsTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AccountsFixtures
  import Mox

  alias Amanogawa.Accounts
  alias Amanogawa.Accounts.MagicLink
  alias Amanogawa.Accounts.MagicLinkToken
  alias Amanogawa.Accounts.User
  alias Amanogawa.MagicLinkNotifierMock
  alias Amanogawa.Repo

  setup :verify_on_exit!

  describe "generate_magic_link_token/1 + redeem_magic_link_token/1 (happy path)" do
    test "generating then redeeming creates the user with the normalized email and consumes the token" do
      email = "  User@Example.COM  "

      assert {:ok, {clear_token, %MagicLinkToken{}}} = Accounts.generate_magic_link_token(email)

      assert {:ok, %User{email: "user@example.com"}} =
               Accounts.redeem_magic_link_token(clear_token)

      assert Repo.aggregate(MagicLinkToken, :count) == 0
    end

    test "redeeming for an email that already has an account returns the existing account" do
      user = user_fixture()
      {clear_token, _token} = magic_link_token_fixture(email: user.email)

      assert {:ok, %User{id: id}} = Accounts.redeem_magic_link_token(clear_token)
      assert id == user.id
      assert Repo.aggregate(User, :count) == 1
    end
  end

  describe "edge case: invalidation of previous tokens on a new request" do
    test "only the second of two successive tokens for the same email is redeemable" do
      email = "user@example.com"

      assert {:ok, {first_token, _}} = Accounts.generate_magic_link_token(email)
      assert {:ok, {second_token, _}} = Accounts.generate_magic_link_token(email)

      assert :error = Accounts.redeem_magic_link_token(first_token)
      assert {:ok, %User{email: ^email}} = Accounts.redeem_magic_link_token(second_token)
    end

    test "different casings of the same email share invalidation and the same account" do
      assert {:ok, {stale_token, _}} = Accounts.generate_magic_link_token("User@Example.com")
      assert {:ok, {fresh_token, _}} = Accounts.generate_magic_link_token("USER@example.COM")

      assert :error = Accounts.redeem_magic_link_token(stale_token)

      assert {:ok, %User{email: "user@example.com"}} =
               Accounts.redeem_magic_link_token(fresh_token)

      assert Repo.aggregate(User, :count) == 1
    end
  end

  describe "edge case: the clear token never touches the database" do
    test "the persisted token_hash column never equals the clear token handed to the caller" do
      assert {:ok, {clear_token, token}} = Accounts.generate_magic_link_token("user@example.com")

      refute token.token_hash == clear_token
      assert token.token_hash == :crypto.hash(:sha256, clear_token)

      [row] = Repo.all(MagicLinkToken)
      refute row.token_hash == clear_token
    end
  end

  describe "error case: malformed or unknown tokens" do
    setup do
      {:ok, {clear_token, _token}} = Accounts.generate_magic_link_token("user@example.com")
      %{clear_token: clear_token}
    end

    test "an altered token is rejected", %{clear_token: clear_token} do
      {:ok, bytes} = Base.url_decode64(clear_token, padding: false)
      <<first_byte, rest::binary>> = bytes
      # Flips exactly one bit: guaranteed different from the original byte,
      # unlike a fixed character replacement that could coincidentally
      # match (and silently leave the token unaltered).
      altered_bytes = <<:erlang.bxor(first_byte, 1), rest::binary>>
      altered = Base.url_encode64(altered_bytes, padding: false)

      assert :error = Accounts.redeem_magic_link_token(altered)
    end

    test "an empty token is rejected" do
      assert :error = Accounts.redeem_magic_link_token("")
    end

    test "a non-binary value is rejected without raising" do
      assert :error = MagicLink.verify(nil)
      assert :error = MagicLink.verify(123)
      assert :error = MagicLink.verify(%{})
    end

    test "a binary not decodable as URL-safe base64 is rejected" do
      assert :error = Accounts.redeem_magic_link_token("not base64 at all!!")
    end

    test "a well-formed but unknown token is rejected" do
      unknown = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
      assert :error = Accounts.redeem_magic_link_token(unknown)
    end
  end

  describe "error case: invalid email" do
    test "an email without an @ is rejected without creating a token" do
      assert {:error, changeset} = Accounts.generate_magic_link_token("sans-arobase")
      assert "must be a valid email address" in errors_on(changeset).email
      assert Repo.aggregate(MagicLinkToken, :count) == 0
    end

    test "an empty email is rejected" do
      assert {:error, changeset} = Accounts.generate_magic_link_token("")
      assert errors_on(changeset).email
    end

    test "an email longer than 160 characters is rejected" do
      too_long = String.duplicate("a", 155) <> "@a.com"
      assert String.length(too_long) > 160
      assert {:error, changeset} = Accounts.generate_magic_link_token(too_long)
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end
  end

  describe "limit case: 15-minute validity window" do
    test "a token inserted just under 15 minutes ago is still accepted" do
      inserted_at = DateTime.add(DateTime.utc_now(), -15 * 60 + 1, :second)
      {clear_token, _token} = magic_link_token_fixture(inserted_at: inserted_at)

      assert {:ok, %User{}} = Accounts.redeem_magic_link_token(clear_token)
    end

    test "a token inserted just over 15 minutes ago is refused" do
      inserted_at = DateTime.add(DateTime.utc_now(), -15 * 60 - 1, :second)
      {clear_token, _token} = magic_link_token_fixture(inserted_at: inserted_at)

      assert :error = Accounts.redeem_magic_link_token(clear_token)
    end
  end

  describe "limit case: concurrent consumption of the same token" do
    test "exactly one of two concurrent redemptions succeeds" do
      {clear_token, _token} = magic_link_token_fixture()

      results =
        [
          Task.async(fn -> Accounts.redeem_magic_link_token(clear_token) end),
          Task.async(fn -> Accounts.redeem_magic_link_token(clear_token) end)
        ]
        |> Task.await_many()

      assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
      assert Enum.count(results, &(&1 == :error)) == 1
    end
  end

  describe "purge_expired_magic_link_tokens/0" do
    test "deletes expired tokens, preserves valid ones, and returns the exact count" do
      expired_inserted_at = DateTime.add(DateTime.utc_now(), -20 * 60, :second)
      magic_link_token_fixture(inserted_at: expired_inserted_at)
      magic_link_token_fixture(inserted_at: expired_inserted_at)
      {valid_clear_token, _valid_token} = magic_link_token_fixture()

      assert Accounts.purge_expired_magic_link_tokens() == 2
      assert Repo.aggregate(MagicLinkToken, :count) == 1
      assert {:ok, %User{}} = Accounts.redeem_magic_link_token(valid_clear_token)
    end
  end

  describe "get_user!/1 and get_user_by_email/1" do
    test "get_user!/1 fetches a user by id" do
      user = user_fixture()
      assert Accounts.get_user!(user.id).id == user.id
    end

    test "get_user_by_email/1 normalizes before lookup" do
      user = user_fixture(email: "person@example.com")
      assert Accounts.get_user_by_email("  Person@Example.COM  ").id == user.id
    end

    test "get_user_by_email/1 returns nil for an unknown email" do
      assert Accounts.get_user_by_email("nobody@example.com") == nil
    end
  end

  describe "property: normalize -> verify round trip" do
    property "generate then redeem always authenticates the normalized email" do
      check all local <- email_local_part(),
                domain <- email_domain_part() do
        email = "#{local}@#{domain}"

        assert {:ok, {clear_token, _}} = Accounts.generate_magic_link_token(email)

        assert {:ok, %User{email: normalized_email}} =
                 Accounts.redeem_magic_link_token(clear_token)

        assert normalized_email == User.normalize_email(email)
      end
    end
  end

  describe "property: hostile tokens never succeed and never raise" do
    property "for any binary distinct from an issued clear token, redemption is always :error" do
      {:ok, {issued_clear_token, _}} = Accounts.generate_magic_link_token(unique_email())

      check all candidate <- StreamData.binary(max_length: 100),
                candidate != issued_clear_token do
        assert Accounts.redeem_magic_link_token(candidate) == :error
      end
    end
  end

  describe "deliver_magic_link/3 happy path" do
    test "returns :ok, calls the notifier once with a URL carrying the token and the requested locale" do
      email = unique_email()
      Gettext.put_locale(AmanogawaWeb.Gettext, "en")
      on_exit(fn -> Gettext.put_locale(AmanogawaWeb.Gettext, "fr") end)

      expect(MagicLinkNotifierMock, :deliver, fn received_email, url, locale ->
        assert received_email == email
        assert locale == "en"
        send(self(), {:captured_url, url})
        :ok
      end)

      assert :ok =
               Accounts.deliver_magic_link(email, unique_ip(), fn token ->
                 "https://amanogawa.example/connexion/#{token}"
               end)

      assert_receive {:captured_url, url}
      assert url =~ ~r{^https://amanogawa\.example/connexion/}
    end
  end

  describe "deliver_magic_link/3 edge case: anti-enumeration" do
    test "an email with an existing account and one without behave identically" do
      known = user_fixture()
      unknown_email = unique_email()

      expect(MagicLinkNotifierMock, :deliver, 2, fn _email, _url, _locale -> :ok end)

      assert Accounts.deliver_magic_link(known.email, unique_ip(), & &1) ==
               Accounts.deliver_magic_link(unknown_email, unique_ip(), & &1)
    end
  end

  describe "deliver_magic_link/3 error case: notifier failure" do
    test "is swallowed: the facade still returns :ok and the generated token stays redeemable" do
      email = unique_email()

      expect(MagicLinkNotifierMock, :deliver, fn _email, _url, _locale -> {:error, :smtp_down} end)

      capture_token = fn token ->
        send(self(), {:token, token})
        token
      end

      assert :ok = Accounts.deliver_magic_link(email, unique_ip(), capture_token)

      assert_receive {:token, token}
      assert {:ok, %User{email: ^email}} = Accounts.redeem_magic_link_token(token)
    end
  end

  describe "deliver_magic_link/3 error case: invalid email" do
    test "is rejected before throttle or notifier: neither counter is consumed" do
      ip = unique_ip()

      assert {:error, changeset} = Accounts.deliver_magic_link("sans-arobase", ip, & &1)
      assert "must be a valid email address" in errors_on(changeset).email
      assert Repo.aggregate(MagicLinkToken, :count) == 0

      # The IP still has its full quota afterward: the invalid attempt
      # above consumed neither the IP nor the email counter.
      expect(MagicLinkNotifierMock, :deliver, 5, fn _e, _u, _l -> :ok end)

      for _n <- 1..5 do
        assert :ok = Accounts.deliver_magic_link(unique_email(), ip, & &1)
      end
    end
  end

  describe "deliver_magic_link/3 limit case: IP throttle" do
    test "the 6th request from the same IP is denied without a token or a notifier call" do
      ip = unique_ip()
      expect(MagicLinkNotifierMock, :deliver, 5, fn _e, _u, _l -> :ok end)

      for _n <- 1..5 do
        assert :ok = Accounts.deliver_magic_link(unique_email(), ip, & &1)
      end

      count_before = Repo.aggregate(MagicLinkToken, :count)
      assert {:error, :rate_limited} = Accounts.deliver_magic_link(unique_email(), ip, & &1)
      assert Repo.aggregate(MagicLinkToken, :count) == count_before
    end
  end

  describe "deliver_magic_link/3 limit case: email throttle" do
    test "the 6th request for the same email (any casing) from different IPs is denied" do
      email = "Person@Example.com"
      expect(MagicLinkNotifierMock, :deliver, 5, fn _e, _u, _l -> :ok end)

      for _n <- 1..5 do
        assert :ok = Accounts.deliver_magic_link(String.upcase(email), unique_ip(), & &1)
      end

      count_before = Repo.aggregate(MagicLinkToken, :count)

      assert {:error, :rate_limited} =
               Accounts.deliver_magic_link(String.downcase(email), unique_ip(), & &1)

      assert Repo.aggregate(MagicLinkToken, :count) == count_before
    end
  end

  describe "deliver_magic_link/3 property: composition with #030" do
    property "the URL handed to the notifier always authenticates the normalized email it was issued for" do
      stub(MagicLinkNotifierMock, :deliver, fn _email, url, _locale ->
        send(self(), {:url, url})
        :ok
      end)

      check all local <- email_local_part(),
                domain <- email_domain_part() do
        email = "#{local}@#{domain}"

        assert :ok = Accounts.deliver_magic_link(email, unique_ip(), & &1)
        assert_receive {:url, token}
        assert {:ok, %User{email: normalized_email}} = Accounts.redeem_magic_link_token(token)
        assert normalized_email == User.normalize_email(email)
      end
    end
  end

  defp unique_ip, do: "10.0.0.#{System.unique_integer([:positive, :monotonic])}"

  defp email_local_part do
    StreamData.string(?a..?z, min_length: 1, max_length: 10)
  end

  defp email_domain_part do
    StreamData.string(?a..?z, min_length: 1, max_length: 10)
    |> StreamData.map(&(&1 <> ".com"))
  end
end
