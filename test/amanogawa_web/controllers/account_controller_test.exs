defmodule AmanogawaWeb.AccountControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures

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
      assert body["format_version"] == 1
    end

    test "anonymous: redirects to /connexion, no data leaked", %{conn: conn} do
      conn = get(conn, ~p"/compte/export")

      assert redirected_to(conn) == ~p"/connexion"
      refute conn.resp_body =~ "email"
    end
  end
end
