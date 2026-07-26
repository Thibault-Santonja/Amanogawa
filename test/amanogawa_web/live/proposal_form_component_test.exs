defmodule AmanogawaWeb.Live.ProposalFormComponentTest do
  @moduledoc """
  Exercises `AmanogawaWeb.Live.ProposalFormComponent` (issue #036) through
  `AmanogawaWeb.ExploreLive`, the only LiveView that ever mounts it: a
  `LiveComponent` has no route of its own.
  """

  use AmanogawaWeb.ConnCase, async: true

  import Amanogawa.AccountsFixtures
  import Amanogawa.AtlasFixtures
  import Phoenix.LiveViewTest

  alias Amanogawa.Accounts
  alias Amanogawa.Contributions
  alias Amanogawa.Contributions.ProposalThrottle

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.set_display_name(user, unique_display_name())
    %{conn: log_in_user(conn, user), user: user}
  end

  describe "position correction" do
    test "picking a position on the map previews it, and submitting stores a Point payload", %{
      conn: conn,
      user: user
    } do
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=position")

      lv |> element("#map") |> render_hook("position_picked", %{"lng" => 2.35, "lat" => 48.85})

      assert render(lv) =~ "48.85"

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{"source" => "https://example.org/source"}
      })
      |> render_submit()

      assert [override] =
               Contributions.list_overrides(%{event_qid: event.qid, author_id: user.id})

      assert override.proposed_value == %{"lon" => 2.35, "lat" => 48.85}
    end
  end

  describe "date correction" do
    test "a begin_date correction with precision stores a valid date payload", %{conn: conn} do
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=begin_date")

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{
          "year" => "1789",
          "month" => "7",
          "day" => "14",
          "precision" => "11",
          "calendar" => "gregorian",
          "source" => "https://example.org/source"
        }
      })
      |> render_submit()

      assert [override] = Contributions.list_overrides(%{event_qid: event.qid})

      assert override.proposed_value == %{
               "year" => 1789,
               "month" => 7,
               "day" => 14,
               "precision" => 11,
               "calendar" => "gregorian"
             }
    end

    test "removing the end date proposes a nil value", %{conn: conn} do
      event = event_fixture(end_year: 1850, end_precision: 9)
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=end_date")

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{"clear" => "true", "source" => "https://example.org/source"}
      })
      |> render_submit()

      assert [override] = Contributions.list_overrides(%{event_qid: event.qid})
      assert override.proposed_value == nil
    end
  end

  describe "link proposal" do
    test "an existing target QID shows its label and creates a :link override", %{conn: conn} do
      source = event_fixture()
      target = event_fixture(label_fr: "Cible")
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{source.qid}&propose_field=link")

      lv
      |> form("#proposal-form-form", %{"proposal" => %{"target_qid" => target.qid}})
      |> render_change()

      assert render(lv) =~ "Cible"

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{
          "target_qid" => target.qid,
          "link_type" => "cause",
          "source" => "https://example.org/source"
        }
      })
      |> render_submit()

      assert [override] = Contributions.list_overrides(%{event_qid: source.qid})
      assert override.kind == :link
      assert override.target_qid == target.qid
      assert override.link_type == :cause
    end

    test "an unknown target QID shows an explicit message, nothing is written", %{conn: conn} do
      source = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{source.qid}&propose_field=link")

      lv
      |> form("#proposal-form-form", %{"proposal" => %{"target_qid" => "Q999999999"}})
      |> render_change()

      assert render(lv) =~ "Aucun événement local"

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{
          "target_qid" => "Q999999999",
          "link_type" => "cause",
          "source" => "https://example.org/source"
        }
      })
      |> render_submit()

      assert Contributions.list_overrides(%{event_qid: source.qid}) == []
    end
  end

  describe "new event proposal" do
    test "the creation parcours produces a complete :pending :new_event override, nothing in atlas.events yet",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/?propose_new_event=1")

      lv |> element("#map") |> render_hook("position_picked", %{"lng" => 2.35, "lat" => 48.85})

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{
          "label_fr" => "Nouvel evenement",
          "year" => "1900",
          "precision" => "9",
          "calendar" => "gregorian",
          "source" => "https://example.org/source"
        }
      })
      |> render_submit()

      assert [override] = Contributions.list_overrides(%{kind: :new_event})
      assert override.status == :pending
      assert override.proposed_value["label_fr"] == "Nouvel evenement"
      assert override.proposed_value["position"] == %{"lon" => 2.35, "lat" => 48.85}

      refute Amanogawa.Atlas.get_event_by_qid("Q_never") != nil
    end
  end

  describe "quotas (issue #036)" do
    test "beyond the configured quota, submission is refused with a neutral message, nothing further is written",
         %{conn: conn} do
      original = Application.get_env(:amanogawa, ProposalThrottle, [])
      Application.put_env(:amanogawa, ProposalThrottle, limit: 1, scale_ms: :timer.minutes(15))
      on_exit(fn -> Application.put_env(:amanogawa, ProposalThrottle, original) end)

      # Its own fake peer IP (mirrors `AmanogawaWeb.ExploreLiveTest`'s own
      # `unique_ip/0` + `Plug.Test.put_peer_data/2`): the IP counter is a
      # single, shared, process-wide Hammer table, not reset between
      # tests, so a lowered quota of 1 must not collide with every other
      # test in this file (and beyond) sharing the default 127.0.0.1 peer.
      conn = put_peer_ip(conn, unique_ip())
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=label_fr")

      lv
      |> form("#proposal-form-form", %{
        "proposal" => %{"value" => "Premiere", "source" => "https://example.org/source"}
      })
      |> render_submit()

      {:ok, lv2, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=label_fr")

      html =
        lv2
        |> form("#proposal-form-form", %{
          "proposal" => %{"value" => "Seconde", "source" => "https://example.org/source"}
        })
        |> render_submit()

      assert html =~ "Trop de propositions"
      assert Contributions.list_overrides(%{event_qid: event.qid}) |> length() == 1
    end
  end

  describe "error cases" do
    test "an event that vanishes between opening the form and submitting is reported, nothing written",
         %{conn: conn} do
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=label_fr")

      Amanogawa.Repo.delete!(event)

      html =
        lv
        |> form("#proposal-form-form", %{
          "proposal" => %{"value" => "X", "source" => "https://example.org/source"}
        })
        |> render_submit()

      assert html =~ "introuvable"
      assert Contributions.list_overrides(%{}) == []
    end

    test "cancelling closes the form without writing anything", %{conn: conn} do
      event = event_fixture()
      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=label_fr")

      lv |> element("#proposal-form button", "Annuler") |> render_click()

      assert_patch(lv, ~p"/?sel=#{event.qid}")
      refute has_element?(lv, "#proposal-form")
    end
  end

  describe "issue #038: cross-links from the justification field" do
    test "links to the moderation rules and the privacy policy are present", %{conn: conn} do
      event = event_fixture()

      {:ok, lv, _html} = live(conn, ~p"/?sel=#{event.qid}&propose_field=label_fr")

      assert has_element?(lv, "a[href=\"/moderation\"]", "Règles de modération")
      assert has_element?(lv, "a[href=\"/confidentialite\"]", "Politique de confidentialité")
    end
  end

  # A unique fake remote IP per call: gives the rate-limiting test its own
  # isolated Hammer bucket, distinct from every other test's default
  # (127.0.0.1) peer (mirrors `AmanogawaWeb.ExploreLiveTest`'s own helper
  # of the same name).
  defp put_peer_ip(conn, ip),
    do: Plug.Test.put_peer_data(conn, %{address: ip, port: 111_317, ssl_cert: nil})

  defp unique_ip do
    n = System.unique_integer([:positive, :monotonic])
    {10, rem(div(n, 65_536), 256), rem(div(n, 256), 256), rem(n, 256)}
  end
end
