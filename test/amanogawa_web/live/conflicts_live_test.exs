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
end
