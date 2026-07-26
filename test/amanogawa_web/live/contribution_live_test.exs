defmodule AmanogawaWeb.ContributionLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.DecisionNotifierMock
  alias Amanogawa.Repo

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

    test "a malformed id (not a UUID) shows the same neutral error, never a 500", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/contributions/not-a-uuid")

      assert html =~ "introuvable"
    end

    test "security: a forged calendar in stored data renders the page instead of crashing it", %{
      conn: conn
    } do
      # Forged/legacy data written straight past the changeset (the
      # changeset itself now rejects this at proposal): the PUBLIC page
      # must degrade to "no value", never crash.
      override =
        override_fixture(field: :end_date, current_value: nil, proposed_value: nil)
        |> Ecto.Changeset.change(
          current_value: %{
            "year" => 1800,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "banana"
          },
          proposed_value: %{
            "year" => 1750,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "not_a_calendar"
          }
        )
        |> Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ override.source
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

  describe "issue #038: attribution" do
    test "shows the author's public pseudonym, never the email", %{conn: conn} do
      author = user_fixture()
      author |> Ecto.Changeset.change(display_name: "Historien42") |> Repo.update!()
      override = override_fixture(author_id: author.id)

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Historien42"
      refute html =~ author.email
    end

    test "an anonymized author shows \"compte supprimé\"", %{conn: conn} do
      override = override_fixture(author_id: nil)

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "compte supprimé"
    end

    test "a revision's own actor (the reviewer) is attributed by pseudonym, never email", %{
      conn: conn
    } do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :accepted, _m, _p, _l -> :ok end)
      {:ok, accepted} = Contributions.accept_override(override.id, reviewer, "Motif public")

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{accepted.id}")

      assert html =~ reviewer.display_name
      assert html =~ "Motif public"
      refute html =~ reviewer.email
    end
  end

  describe "issue #038: before/after diff formatted by kind" do
    test "a label correction shows before and after values", %{conn: conn} do
      override =
        override_fixture(
          field: :label_fr,
          current_value: %{"value" => "Ancien nom"},
          proposed_value: %{"value" => "Nouveau nom"}
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Ancien nom"
      assert html =~ "Nouveau nom"
    end

    test "a date correction formats before/after by precision (year only)", %{conn: conn} do
      override =
        override_fixture(
          field: :begin_date,
          current_value: %{
            "year" => -700,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          },
          proposed_value: %{
            "year" => -650,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "701 av. J.-C."
      assert html =~ "651 av. J.-C."
    end

    test "clearing an end date (proposed_value nil) shows \"aucune valeur\"", %{conn: conn} do
      override =
        override_fixture(
          field: :end_date,
          current_value: %{
            "year" => 100,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          },
          proposed_value: nil
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "aucune valeur"
    end

    test "a position correction shows before/after coordinates", %{conn: conn} do
      override =
        override_fixture(
          field: :position,
          current_value: %{"lon" => 2.35, "lat" => 48.86, "location_source" => "direct"},
          proposed_value: %{"lon" => 2.4, "lat" => 48.9}
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "48.86, 2.35"
      assert html =~ "48.9, 2.4"
    end

    test "a link proposal shows the link type and the target event's label", %{conn: conn} do
      target = event_fixture(label_fr: "Bataille de Marathon")

      override =
        override_fixture(
          kind: :link,
          field: nil,
          current_value: nil,
          proposed_value: nil,
          target_qid: target.qid,
          link_type: :cause
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Bataille de Marathon"
      assert html =~ "cause"
    end

    test "a link proposal to a target that no longer resolves falls back to its raw qid", %{
      conn: conn
    } do
      override =
        override_fixture(
          kind: :link,
          field: nil,
          current_value: nil,
          proposed_value: nil,
          target_qid: "Q999999999",
          link_type: :follows
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Q999999999"
      assert html =~ "suit"
    end

    test "an English label correction exercises the :label_en field label", %{conn: conn} do
      override =
        override_fixture(
          field: :label_en,
          current_value: %{"value" => "Old name"},
          proposed_value: %{"value" => "New name"}
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Old name"
      assert html =~ "New name"
      assert html =~ "anglais"
    end

    test "a new event proposal shows its label, description, date and position", %{conn: conn} do
      override =
        override_fixture(
          kind: :new_event,
          field: nil,
          current_value: nil,
          proposed_value: %{
            "label_fr" => "Nouvel évènement",
            "label_en" => nil,
            "description_fr" => "Une description",
            "description_en" => nil,
            "begin_date" => %{
              "year" => 100,
              "month" => nil,
              "day" => nil,
              "precision" => 9,
              "calendar" => "gregorian"
            },
            "position" => %{"lon" => 2.35, "lat" => 48.86}
          }
        )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Nouvel évènement"
      assert html =~ "Une description"
      assert html =~ "48.86, 2.35"
    end
  end

  describe "issue #038: revision history, including system-triggered actions" do
    test "a :superseded revision (sync-triggered) never attributes an actor line to it", %{
      conn: conn
    } do
      author = user_fixture()
      author |> Ecto.Changeset.change(display_name: "Historien42") |> Repo.update!()
      override = accepted_override_fixture(author_id: author.id)

      revision_fixture(override_id: override.id, action: :superseded, actor_id: nil, message: nil)

      {:ok, lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "synchronisation"
      # The revision row itself carries no actor line (system action): the
      # ONLY place "compte supprimé"/a name could appear is the override's
      # own author line above, which correctly shows "Historien42".
      refute has_element?(lv, "li", "compte supprimé")
      assert html =~ "Historien42"
    end

    test "a :conflict_resolved revision (keeping the local correction) shows its motive", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      override = accepted_override_fixture()
      conflict = conflict_fixture(override: override)

      assert {:ok, _resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :kept_override,
                 message: "Correction confirmée par une seconde source"
               })

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Conflit résolu"
      assert html =~ "Correction confirmée par une seconde source"
    end

    test "an :adopted_wikidata resolution attributes the deciding reviewer, never the sync", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      override = accepted_override_fixture()
      conflict = conflict_fixture(override: override)

      assert {:ok, _resolved} =
               Contributions.resolve_conflict(conflict.id, reviewer, %{
                 resolution: :adopted_wikidata,
                 message: "Wikidata porte la bonne valeur"
               })

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Valeur Wikidata adoptée"
      assert html =~ reviewer.display_name
      assert html =~ "Wikidata porte la bonne valeur"
      refute html =~ reviewer.email
    end

    test "an event whose reference no longer resolves falls back to its raw qid", %{conn: conn} do
      override = override_fixture(event_qid: "Q999999999")

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Q999999999"
    end

    test "an :anonymized revision (RGPD) never shows \"compte supprimé\" as an actor line", %{
      conn: conn
    } do
      override = override_fixture(author_id: nil)

      revision_fixture(
        override_id: override.id,
        action: :anonymized,
        actor_id: nil,
        message: nil
      )

      {:ok, _lv, html} = live(conn, ~p"/contributions/#{override.id}")

      assert html =~ "Auteur anonymisé"
    end

    test "the full state machine: proposed, rejected, appealed, appeal_reviewed, all dated and motivated",
         %{conn: conn} do
      author = user_fixture()
      reviewer = reviewer_fixture()
      override = override_fixture(author_id: author.id)

      expect(DecisionNotifierMock, :deliver, fn _e, :rejected, _m, _p, _l -> :ok end)

      {:ok, rejected} =
        Contributions.reject_override(override.id, reviewer, "Source insuffisante")

      conn = log_in_user(conn, author)
      {:ok, lv, _html} = live(conn, ~p"/contributions/#{rejected.id}")

      lv
      |> form("form[phx-submit=\"submit_appeal\"]", %{"appeal" => %{"text" => "Voici une source"}})
      |> render_submit()

      expect(DecisionNotifierMock, :deliver, fn _e, :appeal_accepted, _m, _p, _l -> :ok end)

      assert {:ok, _final} =
               Contributions.review_appeal(rejected.id, reviewer, %{
                 decision: :accepted,
                 message: "Appel accepté, source vérifiée"
               })

      {:ok, _lv2, html} = live(conn, ~p"/contributions/#{rejected.id}")

      assert html =~ "Source insuffisante"
      assert html =~ "Voici une source"
      assert html =~ "Appel accepté, source vérifiée"
    end
  end
end
