defmodule AmanogawaWeb.AccountControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures

  alias Amanogawa.ContributionsFixtures

  describe "GET /compte/export" do
    test "connected: 200, application/json, attachment, no-store, decodable body with the email",
         %{
           conn: conn
         } do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/compte/export")

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "application/json"

      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "amanogawa-export-"

      assert get_resp_header(conn, "cache-control") == ["no-store"]

      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["account"]["email"] == user.email
      assert body["format_version"] == 2
    end

    test "anonymous: redirects to /connexion, no data leaked", %{conn: conn} do
      conn = get(conn, ~p"/compte/export")

      assert redirected_to(conn) == ~p"/connexion"
      refute conn.resp_body =~ "email"
    end

    # Issue #038: RGPD export extends to contributions, composed in the
    # web layer (`Amanogawa.Accounts` never learns `Amanogawa.
    # Contributions` exists).
    test "issue #038: format_version 2 carries a contributions key, empty for a pre-F08 account",
         %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/compte/export")

      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert body["format_version"] == 2
      assert body["contributions"] == []
    end

    test "issue #038: a contributor's export lists their contributions with revisions", %{
      conn: conn
    } do
      user = user_fixture()
      override = ContributionsFixtures.override_fixture(author_id: user.id)

      ContributionsFixtures.revision_fixture(
        override_id: override.id,
        action: :proposed,
        actor_id: user.id
      )

      conn = conn |> log_in_user(user) |> get(~p"/compte/export")

      assert {:ok, body} = Jason.decode(conn.resp_body)
      assert [exported] = body["contributions"]
      assert exported["id"] == override.id
      assert [revision] = exported["revisions"]
      assert revision["action"] == "proposed"
    end
  end
end
