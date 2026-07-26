defmodule AmanogawaWeb.E2E.ContributionJourneyTest do
  @moduledoc """
  The complete contributor journey (issue #039, F08's exit criterion for
  phase 2): sign in by magic link (issue #032's real GET/POST flow,
  factored into `AmanogawaWeb.E2EHelpers.sign_in_via_magic_link/2`),
  choose a public pseudonym, select an event on the map, propose a
  correction of its begin date (with precision and a justification), and
  verify the ethical invariants a `Phoenix.LiveViewTest` process cannot
  see from a real browser: the value on the map/panel stays UNCHANGED
  until a reviewer decides, and the pending proposal is findable on the
  public `/contributions` feed without any special permission.

  Selection goes through the test-only hook witness
  (`AmanogawaWeb.E2EHelpers.select_event/2`), same reasoning as
  `test/e2e/explore_journey_test.exs`: this journey's assertions are
  about the contribution workflow, not WebGL canvas hit-testing.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Amanogawa.AccountsFixtures
  alias Wallaby.Query

  @event_qid "Q31900"

  setup do
    AmanogawaWeb.FeatureCase.share_swoosh_mailbox()

    event =
      AtlasFixtures.event_fixture(%{
        qid: @event_qid,
        label_fr: "Bataille de Marathon",
        label_en: "Battle of Marathon",
        begin_year: -490,
        begin_precision: 9,
        geom: %Geo.Point{coordinates: {23.9750, 38.1128}, srid: 4326}
      })

    %{event: event}
  end

  feature "propose a date correction with a justification, the map stays unchanged until review, the proposal is public and pending",
          %{session: session, event: event} do
    email = AccountsFixtures.unique_email()

    session
    |> visit("/")
    |> wait_for_map_ready()
    |> sign_in_via_magic_link(email)
    |> wait_for_map_ready()

    session
    |> select_event(event.qid)
    |> assert_has(Query.css("#event-panel", text: "Bataille de Marathon"))

    # Opens the date-correction form through the REAL correction link
    # (`AmanogawaWeb.Components.EventPanel`'s `<details>` disclosure),
    # never a fresh `visit/2` to the same URL: a brand new page load
    # spins up a brand new MapLibre instance, whose own initial
    # "moveend"/settle event pushes a `map_moved` intent moments after
    # mount (`AmanogawaWeb.ExploreLive.handle_event("map_moved", ...)`),
    # which `push_patch`es a URL that never carries `propose_field`
    # (`patch_path/2`'s own contract, `AmanogawaWeb.Components.
    # EventPanel`'s moduledoc: "jamais propose_field/propose_new_event"),
    # clobbering the just-opened form an instant after it appeared. The
    # ALREADY-connected map (this session's, settled since the earlier
    # `wait_for_map_ready/1`) never re-fires that spurious event, so a
    # `push_patch` from clicking the correction link is the deterministic
    # path here (`retry_stale/2` covers the residual real-browser
    # click/render race).
    session
    |> retry_stale(&click(&1, Query.css("#propose-correction summary")))
    |> assert_has(Query.css("a[href*='propose_field=begin_date']"))
    |> click_via_js("a[href*='propose_field=begin_date']")

    # First proposal: the pseudonym gate blocks the rest of the form
    # (issue #036/#034, F08 overview's "exigé avant la première
    # proposition").
    session
    |> assert_has(Query.css("#display-name-form"))
    |> retry_stale(
      &fill_in(&1, Query.css("input[name='display_name[display_name]']"), with: "HistorienTest")
    )
    |> retry_stale(&click(&1, Query.css("#display-name-form button", text: "Enregistrer")))

    session
    |> assert_has(Query.css("#proposal-form-form"))
    |> retry_stale(&fill_in(&1, Query.css("input[name='proposal[year]']"), with: "-480"))
    |> retry_stale(
      &fill_in(&1, Query.css("textarea[name='proposal[source]']"),
        with: "https://example.org/marathon-date-corrigee"
      )
    )
    |> retry_stale(
      &click(&1, Query.css("#proposal-form-form button", text: "Envoyer la proposition"))
    )

    session
    |> assert_has(Query.css("#flash-group", text: "Proposition envoyée"))
    # The ethical invariant this journey exists to prove: nothing not yet
    # reviewed ever reaches the map/panel (F08 overview's "la valeur
    # affichée sur la carte reste inchangée"). -490 (astronomical, ADR
    # 0006) formats as "491 av. J.-C." (`Amanogawa.HistoricalDate.
    # Formatter`'s own BCE convention); the proposed -480 would format as
    # "481 av. J.-C.", which must never appear until a reviewer accepts.
    |> assert_has(Query.css("#event-panel", text: "491 av. J.-C."))
    |> refute_has(Query.css("#event-panel", text: "481 av. J.-C."))

    session
    |> visit("/contributions")
    |> assert_has(Query.css("li", text: "Bataille de Marathon"))
    |> assert_has(Query.css("li", text: "En attente"))
    |> assert_has(Query.css("li", text: "HistorienTest"))
  end
end
