defmodule AmanogawaWeb.ConflictsLiveTest do
  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Amanogawa.ContributionsFixtures
  import Phoenix.LiveViewTest

  alias Amanogawa.Atlas
  alias Amanogawa.Contributions

  describe "mount + handle_params" do
    test "reviewer, /relecture/conflits lists open conflicts and resolves them with a motive", %{
      conn: conn
    } do
      reviewer = reviewer_fixture()
      event = event_fixture(begin_year: 1800, begin_precision: 9, label_fr: "Bataille")

      override =
        accepted_override_fixture(
          event_qid: event.qid,
          field: :begin_date,
          proposed_value: %{
            "year" => 1750,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          },
          wikidata_value_at_acceptance: %{
            "year" => 1800,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        )

      # `accepted_override_fixture/1` only builds the Contributions-side
      # row (schema-direct, like every fixture): applying it to the
      # underlying event is what a real `Amanogawa.Contributions.
      # accept_override/3` call would have done, and what this LiveView
      # displays and mutates.
      {:ok, _} = Atlas.apply_field_override(event.qid, :begin_date, override.proposed_value)

      conflict =
        conflict_fixture(
          override: override,
          wikidata_value: %{
            "year" => 1900,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        )

      conn = log_in_user(conn, reviewer)
      {:ok, lv, html} = live(conn, ~p"/relecture/conflits")

      assert html =~ event.qid

      lv
      |> element("#conflicts-#{conflict.id} form")
      |> render_submit(%{"message" => "On garde la correction", "resolution" => "kept_override"})

      refute has_element?(lv, "#conflicts-#{conflict.id}")
      assert Atlas.get_event_by_qid(event.qid).begin_year == 1750
      assert Contributions.list_open_conflicts() == []
    end

    test "connected, non-reviewer is redirected to / with a neutral flash", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/relecture/conflits")
    end

    test "anonymous is redirected to /connexion", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/connexion"}}} = live(conn, ~p"/relecture/conflits")
    end
  end

  describe "human-readable values (i18n finding: no raw inspect)" do
    test "both values render formatted per the field, never as raw Elixir terms", %{conn: conn} do
      reviewer = reviewer_fixture()

      override =
        accepted_override_fixture(
          field: :begin_date,
          proposed_value: %{
            "year" => 1750,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        )

      conflict_fixture(
        override: override,
        wikidata_value: %{
          "year" => 1900,
          "month" => nil,
          "day" => nil,
          "precision" => 9,
          "calendar" => "gregorian"
        }
      )

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture/conflits")

      assert html =~ "1750"
      assert html =~ "1900"
      assert html =~ "Date de début"
      refute html =~ "%{"
    end

    test "an absent Wikidata value renders an honest \"aucune valeur\"", %{conn: conn} do
      reviewer = reviewer_fixture()

      override =
        accepted_override_fixture(
          field: :end_date,
          proposed_value: %{
            "year" => 1840,
            "month" => nil,
            "day" => nil,
            "precision" => 9,
            "calendar" => "gregorian"
          }
        )

      conflict_fixture(override: override, wikidata_value: %{"absent" => true})

      conn = log_in_user(conn, reviewer)
      {:ok, _lv, html} = live(conn, ~p"/relecture/conflits")

      assert html =~ "aucune valeur"
      refute html =~ "%{"
    end
  end

  describe "hostile payloads" do
    test "a forged resolution is refused with a neutral error, nothing resolved", %{conn: conn} do
      reviewer = reviewer_fixture()
      conflict = conflict_fixture()

      conn = log_in_user(conn, reviewer)
      {:ok, lv, _html} = live(conn, ~p"/relecture/conflits")

      html =
        render_hook(lv, "resolve", %{
          "conflict_id" => conflict.id,
          "resolution" => "obsolete",
          "message" => "motif"
        })

      assert html =~ "Impossible de résoudre ce conflit"
      assert [_still_open] = Contributions.list_open_conflicts()
    end
  end
end
