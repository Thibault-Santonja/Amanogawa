defmodule AmanogawaWeb.ProposalControllerTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures

  describe "GET /proposer, authenticated" do
    test "a valid field correction redirects straight to the explore page with the form open", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)
      event = event_fixture()

      conn = get(conn, ~p"/proposer?sel=#{event.qid}&field=label_fr")

      assert redirected_to(conn) == "/?sel=#{event.qid}&propose_field=label_fr"
    end

    test "an invalid qid redirects to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/proposer?sel=not-a-qid&field=label_fr")

      assert redirected_to(conn) == "/"
    end

    test "an unknown field is dropped, redirects to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)
      event = event_fixture()

      conn = get(conn, ~p"/proposer?sel=#{event.qid}&field=not_a_field")

      assert redirected_to(conn) == "/"
    end

    test "the new-event parcours redirects to the explore page with the creation form open", %{
      conn: conn
    } do
      user = user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/proposer?new_event=1")

      assert redirected_to(conn) == "/?propose_new_event=1"
    end

    test "no recognized params redirects to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      conn = get(conn, ~p"/proposer")

      assert redirected_to(conn) == "/"
    end
  end

  describe "GET /proposer, anonymous: F07's return-to mechanic" do
    test "redirects to /connexion and stashes this exact path as user_return_to", %{conn: conn} do
      event = event_fixture()

      conn = get(conn, ~p"/proposer?sel=#{event.qid}&field=label_fr")

      assert redirected_to(conn) == "/connexion"

      assert Plug.Conn.get_session(conn, "user_return_to") ==
               "/proposer?sel=#{event.qid}&field=label_fr"
    end
  end
end
