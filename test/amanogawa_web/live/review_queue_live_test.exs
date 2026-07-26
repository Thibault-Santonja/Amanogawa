defmodule AmanogawaWeb.ReviewQueueLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.DecisionNotifierMock

  setup :verify_on_exit!

  setup do
    stub(DecisionNotifierMock, :deliver, fn _email, _outcome, _message, _path, _locale -> :ok end)
    :ok
  end

  describe "access control" do
    test "connected, non-reviewer is redirected to / with a neutral flash", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/relecture")
    end

    test "anonymous is redirected to /connexion", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/connexion"}}} = live(conn, ~p"/relecture")
    end
  end

  describe "queue ordering and diff" do
    test "reviewer: proposals are listed oldest first, with a typed diff", %{conn: conn} do
      reviewer = reviewer_fixture()
      event = event_fixture(label_fr: "Ancien nom")

      older =
        override_fixture(
          event_qid: event.qid,
          field: :label_fr,
          proposed_value: %{"value" => "Valeur-A"}
        )

      older
      |> Ecto.Changeset.change(inserted_at: DateTime.add(older.inserted_at, -60, :second))
      |> Amanogawa.Repo.update!()

      _newer =
        override_fixture(
          event_qid: event.qid,
          field: :label_fr,
          proposed_value: %{"value" => "Valeur-B"}
        )

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      assert has_element?(lv, "#review-queue")

      queue_html = render(lv)
      {older_index, _} = :binary.match(queue_html, "Valeur-A")
      {newer_index, _} = :binary.match(queue_html, "Valeur-B")
      assert older_index < newer_index
    end

    test "reviewer: a badge signals when the reference value changed since the proposal", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      event = event_fixture(label_fr: "Valeur actuelle")

      override_fixture(
        event_qid: event.qid,
        field: :label_fr,
        current_value: %{"value" => "Ancienne valeur"},
        proposed_value: %{"value" => "Corrigee"}
      )

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      assert has_element?(lv, "#review-queue", "La valeur de référence a changé")
    end

    test "reviewer: a position diff shows an approximate distance and a map link", %{conn: conn} do
      reviewer = reviewer_fixture()
      event = event_fixture(geom: %Geo.Point{coordinates: {2.0, 48.0}, srid: 4326})

      override_fixture(
        event_qid: event.qid,
        field: :position,
        current_value: %{"lon" => 2.0, "lat" => 48.0, "location_source" => "direct"},
        proposed_value: %{"lon" => 2.35, "lat" => 48.85}
      )

      conn = log_in_user(conn, reviewer)
      {:ok, lv, html} = live(conn, ~p"/relecture")

      assert html =~ "Distance approximative"
      assert has_element?(lv, ~s(a[href^="/?lat="]), "Voir sur la carte")
    end

    test "reviewer: a date diff formats both values per their precision", %{conn: conn} do
      reviewer = reviewer_fixture()

      event =
        event_fixture(begin_year: 1800, begin_precision: 9, begin_month: nil, begin_day: nil)

      override_fixture(
        event_qid: event.qid,
        field: :begin_date,
        current_value: %{
          "year" => 1800,
          "month" => nil,
          "day" => nil,
          "precision" => 9,
          "calendar" => "gregorian"
        },
        proposed_value: %{
          "year" => 1750,
          "month" => nil,
          "day" => nil,
          "precision" => 9,
          "calendar" => "gregorian"
        }
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture")

      assert html =~ "1800"
      assert html =~ "1750"
    end

    test "reviewer: a link diff shows both endpoints and the explained link type", %{conn: conn} do
      reviewer = reviewer_fixture()

      for {link_type, label} <- [
            {:part_of, "fait partie de"},
            {:follows, "suit"},
            {:cause, "cause"},
            {:effect, "effet"},
            {:significant, "événement notable lié"}
          ] do
        source = event_fixture(label_fr: "Source")
        target = event_fixture(label_fr: "Cible")

        override_fixture(
          kind: :link,
          event_qid: source.qid,
          target_qid: target.qid,
          link_type: link_type,
          field: nil,
          proposed_value: nil,
          current_value: nil
        )

        conn = log_in_user(conn, reviewer)
        {:ok, _lv, html} = live(conn, ~p"/relecture?event_qid=#{source.qid}")

        assert html =~ "Source"
        assert html =~ "Cible"
        assert html =~ label
      end
    end

    test "reviewer: label/date/position diffs with no prior value render an honest \"none\"", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      event = event_fixture()

      override_fixture(
        event_qid: event.qid,
        field: :label_en,
        current_value: nil,
        proposed_value: %{"value" => "First label"}
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture?event_qid=#{event.qid}")

      assert html =~ "aucune"
    end

    test "reviewer: an end_date diff (with no prior end date) is formatted too", %{conn: conn} do
      reviewer = reviewer_fixture()
      event = event_fixture(end_year: nil)

      override_fixture(
        event_qid: event.qid,
        field: :end_date,
        current_value: nil,
        proposed_value: %{
          "year" => 1850,
          "month" => nil,
          "day" => nil,
          "precision" => 9,
          "calendar" => "gregorian"
        }
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture?event_qid=#{event.qid}")

      assert html =~ "1850"
    end

    test "reviewer: a position diff on an event with no geometry shows an honest \"none\"", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      event = event_fixture(geom: nil, location_source: nil)

      override_fixture(
        event_qid: event.qid,
        field: :position,
        current_value: nil,
        proposed_value: %{"lon" => 2.35, "lat" => 48.85}
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture?event_qid=#{event.qid}")

      assert html =~ "aucune"
    end

    test "reviewer: an empty filter param is ignored, same as absent", %{conn: conn} do
      reviewer = reviewer_fixture()
      conn = log_in_user(conn, reviewer)

      {:ok, lv, _html} = live(conn, ~p"/relecture?kind=")

      assert has_element?(lv, "#review-queue")
    end

    test "reviewer: a new_event diff shows the full proposed sheet", %{conn: conn} do
      reviewer = reviewer_fixture()

      override_fixture(
        kind: :new_event,
        event_qid: nil,
        field: nil,
        current_value: nil,
        proposed_value: %{
          "label_fr" => "Nouvel evenement",
          "label_en" => "New event",
          "description_fr" => "Une description",
          "description_en" => nil,
          "begin_date" => %{
            "year" => 1900,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          },
          "position" => %{"lon" => 2.35, "lat" => 48.85}
        }
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture")

      assert html =~ "Nouvel evenement"
      assert html =~ "Une description"
      assert html =~ "1900"
    end

    test "reviewer: filters the queue by event_qid", %{conn: conn} do
      reviewer = reviewer_fixture()
      event = event_fixture(label_fr: "Cet evenement")
      other_event = event_fixture(label_fr: "Un autre evenement")

      override_fixture(
        event_qid: event.qid,
        field: :label_fr,
        proposed_value: %{"value" => "Valeur-Incluse"}
      )

      override_fixture(
        event_qid: other_event.qid,
        field: :label_fr,
        proposed_value: %{"value" => "Valeur-Exclue"}
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture?event_qid=#{event.qid}")

      assert html =~ "Valeur-Incluse"
      refute html =~ "Valeur-Exclue"
    end

    test "reviewer: filters the queue by kind", %{conn: conn} do
      reviewer = reviewer_fixture()
      source = event_fixture()
      target = event_fixture()

      override_fixture(
        event_qid: source.qid,
        field: :label_fr,
        proposed_value: %{"value" => "Only field"}
      )

      override_fixture(
        kind: :link,
        event_qid: source.qid,
        target_qid: target.qid,
        link_type: :cause,
        field: nil,
        proposed_value: nil,
        current_value: nil
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture?kind=link")

      refute html =~ "Only field"
    end
  end

  describe "decisions" do
    test "reviewer: accepting with a motive removes the row and applies the override via Atlas",
         %{
           conn: conn
         } do
      reviewer = reviewer_fixture()
      event = event_fixture(label_fr: "Ancien nom")

      override =
        override_fixture(
          event_qid: event.qid,
          field: :label_fr,
          proposed_value: %{"value" => "Nouveau nom"}
        )

      expect(DecisionNotifierMock, :deliver, fn _email, :accepted, "Bien vu", _path, "fr" ->
        :ok
      end)

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      render_hook(lv, "decide", %{
        "override_id" => override.id,
        "decision" => "accept",
        "message" => "Bien vu"
      })

      assert Atlas.get_event_by_qid(event.qid).label_fr == "Nouveau nom"
      assert Contributions.get_override(override.id).status == :accepted
    end

    test "reviewer: rejecting without a motive shows an error, override stays pending", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      override = override_fixture()

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      html =
        render_hook(lv, "decide", %{
          "override_id" => override.id,
          "decision" => "reject",
          "message" => ""
        })

      assert html =~ "Un motif est requis"
      assert Contributions.get_override(override.id).status == :pending
    end

    test "reviewer: rejecting with a motive removes the row, journals :rejected", %{conn: conn} do
      reviewer = reviewer_fixture()
      override = override_fixture()

      expect(DecisionNotifierMock, :deliver, fn _email,
                                                :rejected,
                                                "Source douteuse",
                                                _path,
                                                "fr" ->
        :ok
      end)

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      render_hook(lv, "decide", %{
        "override_id" => override.id,
        "decision" => "reject",
        "message" => "Source douteuse"
      })

      refute has_element?(lv, "#review-queue-#{override.id}")
      assert Contributions.get_override(override.id).status == :rejected
    end

    test "reviewer: a self-review attempt is rejected with a neutral message", %{conn: conn} do
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: reviewer.id)

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture")

      html =
        render_hook(lv, "decide", %{
          "override_id" => override.id,
          "decision" => "accept",
          "message" => "motif"
        })

      assert html =~ "propre proposition"
      assert Contributions.get_override(override.id).status == :pending
    end
  end

  describe "appeals" do
    test "reviewer: an appealed proposal shows the author's text and can be tranched", %{
      conn: conn
    } do
      author = user_fixture()
      reviewer = reviewer_fixture()
      event = event_fixture()

      override = override_fixture(event_qid: event.qid, field: :label_fr, author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)
      {:ok, rejected} = Contributions.reject_override(override.id, reviewer, "motif")

      {:ok, _appealed} =
        Contributions.appeal_override(rejected.id, author, "Je ne suis pas d'accord")

      conn = log_in_user(conn, reviewer)
      {:ok, lv, html} = live(conn, ~p"/relecture")

      assert html =~ "Je ne suis pas d&#39;accord"
      assert has_element?(lv, "#review-queue", "En appel")

      expect(DecisionNotifierMock, :deliver, fn _e, :appeal_accepted, _m, _p, _l -> :ok end)

      render_hook(lv, "review_appeal", %{
        "override_id" => rejected.id,
        "decision" => "accepted",
        "message" => "Vu, j'accepte"
      })

      assert Contributions.get_override(rejected.id).status == :accepted
      assert Atlas.get_event_by_qid(event.qid).label_fr == override.proposed_value["value"]
    end
  end
end
