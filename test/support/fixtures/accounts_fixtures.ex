defmodule Amanogawa.AccountsFixtures do
  @moduledoc """
  Canonical builder for Accounts test fixtures. The only place in the
  test suite allowed to construct `Amanogawa.Accounts.User` /
  `MagicLinkToken` rows directly; every other test goes through
  `user_fixture/1` and `magic_link_token_fixture/1`.
  """

  alias Amanogawa.Accounts.MagicLinkToken
  alias Amanogawa.Accounts.User
  alias Amanogawa.Repo

  @doc """
  Inserts a valid user (defaults to a fresh unique email), overridable
  via `attrs`.
  """
  @spec user_fixture(map() | keyword()) :: User.t()
  def user_fixture(attrs \\ %{}) do
    default_attrs = %{email: unique_email()}

    %User{}
    |> User.changeset(Map.merge(default_attrs, Map.new(attrs)))
    |> Repo.insert!()
  end

  @doc """
  Inserts a magic link token row directly, bypassing
  `Amanogawa.Accounts.MagicLink.create/1`: returns `{clear_token,
  token}` so a test can hand `clear_token` to `MagicLink.verify/1` or
  `Amanogawa.Accounts.redeem_magic_link_token/1` while also controlling
  `:inserted_at` precisely, the way limit-case tests of the 15-minute
  validity window pilot the clock instead of waiting on it
  (`.claude/rules/testing.md`: no `Process.sleep`).

  `attrs` may override `:email`, `:inserted_at`, or supply an explicit
  `:clear_token` (defaults to a fresh random one); `:token_hash` is
  always derived from the effective clear token, never independently
  overridable, so the pair returned is always internally consistent.
  """
  @spec magic_link_token_fixture(map() | keyword()) :: {String.t(), MagicLinkToken.t()}
  def magic_link_token_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {clear_token, attrs} = Map.pop(attrs, :clear_token, unique_clear_token())

    default_attrs = %{
      email: unique_email(),
      inserted_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    # `:utc_datetime` (unlike `:utc_datetime_usec`) rejects a value carrying
    # microseconds; truncating whatever the caller passes keeps every call
    # site free to build `inserted_at` with plain `DateTime.add/3` (which
    # inherits `DateTime.utc_now/0`'s microseconds) instead of remembering
    # to truncate itself.
    merged_attrs =
      Map.merge(default_attrs, attrs)
      |> Map.update!(:inserted_at, &DateTime.truncate(&1, :second))

    token =
      %MagicLinkToken{}
      |> Ecto.Changeset.change(merged_attrs)
      |> Ecto.Changeset.put_change(:token_hash, :crypto.hash(:sha256, clear_token))
      |> Repo.insert!()

    {clear_token, token}
  end

  @doc "Returns an email unique to this call."
  @spec unique_email() :: String.t()
  def unique_email, do: "user-#{System.unique_integer([:positive])}@example.com"

  defp unique_clear_token do
    32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end
