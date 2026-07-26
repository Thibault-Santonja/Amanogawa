defmodule AmanogawaWeb.ContributionsLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Phoenix.LiveViewTest

  alias Amanogawa.Repo

  describe "public access" do
    test "anonymous visitor sees the chronological feed", %{conn: conn} do
      event = event_fixture(label_fr: "Bataille ancienne")
      override_fixture(event_qid: event.qid, author_id: user_fixture().id)

      {:ok, lv, html} = live(conn, ~p"/contributions")

      assert html =~ "Bataille ancienne"
      assert has_element?(lv, "#contributions-feed")
    end
  end

  describe "chronological order and attribution" do
    test "most recent first, exact order, author shown as pseudonym never email", %{conn: conn} do
      event = event_fixture()
      author = user_fixture()
      author |> Ecto.Changeset.change(display_name: "Historien42") |> Repo.update!()

      older = override_fixture(event_qid: event.qid, author_id: author.id)

      older
      |> Ecto.Changeset.change(inserted_at: DateTime.add(older.inserted_at, -60, :second))
      |> Repo.update!()

      newer = override_fixture(event_qid: event.qid, author_id: author.id)

      {:ok, _lv, html} = live(conn, ~p"/contributions")

      newer_pos = :binary.match(html, "contributions-#{newer.id}") |> elem(0)
      older_pos = :binary.match(html, "contributions-#{older.id}") |> elem(0)

      assert newer_pos < older_pos
      assert html =~ "Historien42"
      refute html =~ author.email
    end

    test "an anonymized author's contribution shows \"compte supprimé\"", %{conn: conn} do
      event = event_fixture(label_fr: "Fondation de la cité")
      override_fixture(event_qid: event.qid, author_id: nil)

      {:ok, _lv, html} = live(conn, ~p"/contributions")

      assert html =~ "compte supprimé"
      assert html =~ "Fondation de la cité"
    end
  end

  describe "filters (URL, shareable)" do
    test "?status= filters the feed", %{conn: conn} do
      event = event_fixture()
      pending = override_fixture(event_qid: event.qid)
      accepted = accepted_override_fixture(event_qid: event.qid, field: :label_en)

      {:ok, lv, _html} = live(conn, ~p"/contributions?status=accepted")

      assert has_element?(lv, "#contributions-#{accepted.id}")
      refute has_element?(lv, "#contributions-#{pending.id}")
    end

    test "?event= filters to a single event, with a \"retirer\" link", %{conn: conn} do
      event = event_fixture()
      other_event = event_fixture()
      matching = override_fixture(event_qid: event.qid)
      _other = override_fixture(event_qid: other_event.qid)

      {:ok, lv, html} = live(conn, ~p"/contributions?event=#{event.qid}")

      assert has_element?(lv, "#contributions-#{matching.id}")
      assert html =~ event.qid
      assert has_element?(lv, "a", "retirer")
    end

    test "error case: an unknown status query parameter never crashes the page", %{conn: conn} do
      override = override_fixture()

      {:ok, lv, _html} = live(conn, ~p"/contributions?status=not_a_status")

      assert has_element?(lv, "#contributions-#{override.id}")
    end

    test "limit case: no contribution for a filter shows the empty state, not a blank page", %{
      conn: conn
    } do
      {:ok, _lv, html} = live(conn, ~p"/contributions?event=Q999999999")

      assert html =~ "Aucune contribution pour ce filtre."
    end
  end

  describe "pagination (\"charger plus\")" do
    test "shows a load more button beyond the first page, appends the next page on click", %{
      conn: conn
    } do
      event = event_fixture()

      overrides =
        for _ <- 1..3 do
          override = override_fixture(event_qid: event.qid)

          override
          |> Ecto.Changeset.change(
            inserted_at:
              DateTime.add(override.inserted_at, System.unique_integer([:positive]), :second)
          )
          |> Repo.update!()
        end

      oldest = Enum.min_by(overrides, & &1.inserted_at)

      {:ok, lv, _html} = live(conn, ~p"/contributions")

      lv
      |> element("[phx-click=load_more]")
      |> render_click()

      assert has_element?(lv, "#contributions-#{oldest.id}")
    end
  end
end
