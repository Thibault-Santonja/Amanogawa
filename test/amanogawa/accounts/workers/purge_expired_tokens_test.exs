defmodule Amanogawa.Accounts.Workers.PurgeExpiredTokensTest do
  use Amanogawa.DataCase, async: true

  import Amanogawa.AccountsFixtures

  alias Amanogawa.Accounts.MagicLinkToken
  alias Amanogawa.Accounts.SessionToken
  alias Amanogawa.Accounts.Workers.PurgeExpiredTokens
  alias Amanogawa.Repo

  test "purges expired magic link and session tokens in the database and returns :ok" do
    expired_inserted_at = DateTime.add(DateTime.utc_now(), -20 * 60, :second)
    magic_link_token_fixture(inserted_at: expired_inserted_at)
    {_clear_token, _valid_token} = magic_link_token_fixture()

    expired_session_at = DateTime.add(DateTime.utc_now(), -61, :day)
    session_token_fixture(inserted_at: expired_session_at)
    {_valid_clear_token, _valid_session} = session_token_fixture()

    assert :ok = perform_job(PurgeExpiredTokens, %{})
    assert Repo.aggregate(MagicLinkToken, :count) == 1
    assert Repo.aggregate(SessionToken, :count) == 1
  end
end
