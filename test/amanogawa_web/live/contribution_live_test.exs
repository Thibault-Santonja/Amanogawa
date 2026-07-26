defmodule AmanogawaWeb.ContributionLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.ContributionsFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.DecisionNotifierMock

  setup :verify_on_exit!

  setup do
    stub(DecisionNotifierMock, :deliver, fn _email, _outcome, _message, _path, _locale -> :ok end)
    :ok
  end

  describe "public visibility" do
    test "anonymous can open the page and reads the history, no appeal form", %{conn: conn} do
      override = override_fixture()

      {:ok, lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ override.source
      refute has_element?(lv, "form[phx-submit=\"submit_appeal\"]")
    end

    test "an unknown id shows a neutral error, no crash", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/contributions/#{Ecto.UUID.generate()}")

      assert html =~ "introuvable"
    end
  end

  describe "appeal form visibility (anti-IDOR)" do
    test "the author of a rejected proposal without an appeal sees the form", %{conn: conn} do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      conn = log_in_user(conn, author)
      {:ok, lv, _html} = live(conn, ~p"/contributions/#{rejected.id}")

      assert has_element?(lv, "form[phx-submit=\"submit_appeal\"]")
    end

    test "another signed-in user does not see the form", %{conn: conn} do
      author = user_fixture()
      other = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      conn = log_in_user(conn, other)
      {:ok, lv, _html} = live(conn, ~p"/contributions/#{rejected.id}")

      refute has_element?(lv, "form[phx-submit=\"submit_appeal\"]")
    end

    test "an anonymous visitor never sees the form even on a rejected proposal", %{conn: conn} do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      {:ok, lv, _html} = live(conn, ~p"/contributions/#{rejected.id}")

      refute has_element?(lv, "form[phx-submit=\"submit_appeal\"]")
    end

    test "the form disappears once an appeal has been submitted, and cannot be submitted twice",
         %{
           conn: conn
         } do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      conn = log_in_user(conn, author)
      {:ok, lv, _html} = live(conn, ~p"/contributions/#{rejected.id}")

      lv
      |> form("form[phx-submit=\"submit_appeal\"]", %{"appeal" => %{"text" => "Ma reponse"}})
      |> render_submit()

      refute has_element?(lv, "form[phx-submit=\"submit_appeal\"]")
      assert Contributions.get_override(rejected.id).status == :appealed

      {:ok, lv2, _html} = live(conn, ~p"/contributions/#{rejected.id}")
      refute has_element?(lv2, "form[phx-submit=\"submit_appeal\"]")
    end
  end
end
