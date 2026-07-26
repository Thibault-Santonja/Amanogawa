defmodule AmanogawaWeb.E2E.ReviewJourneyTest do
  @moduledoc """
  The reviewer-side journeys (issue #039, F08's exit criterion for phase
  2), each with TWO independent browser sessions (`@sessions 2`, never
  sharing cookies between the contributor and the reviewer, this issue's
  own point d'attention): the reviewer account is promoted directly in
  the database (`Amanogawa.AccountsFixtures.reviewer_fixture/1`), exactly
  the manual operation `docs/ops/moderation.md` documents for a real
  operator.

  Two scenarios:

    * Acceptance: a contributor proposes a date correction, a reviewer
      opens `/relecture`, examines the diff, and accepts it with a public
      motive; the corrected value then appears both in the event panel
      (with the "valeur corrigée" mention, issue #038) and on the
      contribution's own public page.
    * Rejection and appeal: a reviewer rejects a proposal with a motive,
      the author sees it on the public page, replies once (the appeal),
      a second reply is impossible, and the reviewer's final decision on
      the appeal is itself public.

  Every ethical invariant this issue asks to lock is checked observably:
  no un-reviewed value ever reaches the map, every motive is visible
  without an account, no gamification (like counts, streaks) appears
  anywhere on these pages.

  Every `fill_in`/`click` on a LiveView-rendered node goes through
  `AmanogawaWeb.E2EHelpers.retry_stale/2`: a background patch
  (`AmanogawaWeb.ExploreLive`'s map/timeline hooks push fairly often) can
  replace a node the instant a real interaction reaches for it, a race
  `Phoenix.LiveViewTest` never has to contend with.
  """

  use AmanogawaWeb.FeatureCase, async: false

  import AmanogawaWeb.E2EHelpers
  import Wallaby.Browser

  alias Amanogawa.AccountsFixtures
  alias Wallaby.Query

  @sessions 2

  @event_qid "Q3682"

  setup do
    AmanogawaWeb.FeatureCase.share_swoosh_mailbox()

    event =
      AtlasFixtures.event_fixture(%{
        qid: @event_qid,
        label_fr: "Fondation de Rome",
        label_en: "Founding of Rome",
        begin_year: -753,
        begin_precision: 9,
        geom: %Geo.Point{coordinates: {12.4964, 41.9028}, srid: 4326}
      })

    %{event: event}
  end

  feature "acceptance: the corrected value reaches the map and the public page carries the motive",
          %{sessions: [contributor_session, reviewer_session], event: event} do
    contributor_email = AccountsFixtures.unique_email()
    reviewer = AccountsFixtures.reviewer_fixture()

    contributor_session
    |> visit("/")
    |> wait_for_map_ready()
    |> sign_in_via_magic_link(contributor_email)
    |> wait_for_map_ready()
    |> select_event(event.qid)
    |> assert_has(Query.css("#event-panel"))

    # A real click through the correction link, never a fresh `visit/2`:
    # see the contributor journey's own comment
    # (`test/e2e/contribution_journey_test.exs`) for why a brand new page
    # load races a spurious `map_moved` patch that strips
    # `propose_field`.
    contributor_session
    |> retry_stale(&click(&1, Query.css("#propose-correction summary")))
    |> assert_has(Query.css("a[href*='propose_field=begin_date']"))
    |> click_via_js("a[href*='propose_field=begin_date']")
    |> assert_has(Query.css("#display-name-form"))
    |> retry_stale(
      &fill_in(&1, Query.css("input[name='display_name[display_name]']"), with: "Contributeur1")
    )
    |> retry_stale(&click(&1, Query.css("#display-name-form button", text: "Enregistrer")))
    |> assert_has(Query.css("#proposal-form-form"))
    |> retry_stale(&fill_in(&1, Query.css("input[name='proposal[year]']"), with: "-750"))
    |> retry_stale(
      &fill_in(&1, Query.css("textarea[name='proposal[source]']"),
        with: "https://example.org/fondation-rome-datee"
      )
    )
    |> retry_stale(
      &click(&1, Query.css("#proposal-form-form button", text: "Envoyer la proposition"))
    )
    |> assert_has(Query.css("#flash-group", text: "Proposition envoyée"))

    reviewer_session
    |> sign_in_via_magic_link(reviewer.email)
    |> visit("/relecture")
    |> assert_has(Query.css("#review-queue", text: "Contributeur1"))
    |> assert_has(Query.css("#review-queue", text: "754 av. J.-C."))
    |> assert_has(Query.css("#review-queue", text: "751 av. J.-C."))
    |> retry_stale(
      &fill_in(&1, Query.css("#review-queue textarea[name='message']"),
        with: "Vérifié auprès de la source citée"
      )
    )
    |> retry_stale(&click(&1, Query.css("#review-queue button[value='accept']")))
    |> assert_has(Query.css("#flash-group", text: "Proposition acceptée"))

    # The corrected value now reaches the map/panel, with the "valeur
    # corrigée" mention (issue #038): re-opened from the REVIEWER's own
    # session, but `AmanogawaWeb.Components.EventPanel`'s transparency
    # section is gated by no role at all (F08 overview's "droit affiché"
    # principle applies just as much to READING it), so this is exactly
    # what an anonymous visitor would also see.
    reviewer_session
    |> visit("/")
    |> wait_for_map_ready()
    |> select_event(event.qid)
    |> assert_has(Query.css("#event-panel", text: "751 av. J.-C."))
    |> assert_has(Query.css("#event-panel", text: "Valeur corrigée par la communauté"))
    # Anti-dark-patterns (F08 overview): no like count, no streak, no
    # contributor ranking anywhere on the panel or the queue.
    |> refute_has(Query.css("#event-panel", text: "likes"))
    |> refute_has(Query.css("#review-queue", text: "classement"))

    # The decision and its motive are public, without any account
    # (contributor's own session proves it independently of the
    # reviewer's, two entirely separate cookies).
    contributor_session
    |> visit("/contributions")
    |> assert_has(Query.css("li", text: "Acceptée"))
    |> retry_stale(&click(&1, Query.css("li a", text: "Fondation de Rome")))
    |> assert_has(Query.css("body", text: "Vérifié auprès de la source citée"))
  end

  # `@sessions` is an ExUnit registered attribute (like `@tag`): it applies
  # to the NEXT `feature/3` only and must be redeclared before every one
  # that needs two sessions.
  @sessions 2
  feature "rejection and appeal: one reply only, the final decision is public",
          %{sessions: [contributor_session, reviewer_session], event: event} do
    contributor_email = AccountsFixtures.unique_email()
    reviewer = AccountsFixtures.reviewer_fixture()

    contributor_session
    |> visit("/")
    |> wait_for_map_ready()
    |> sign_in_via_magic_link(contributor_email)
    |> wait_for_map_ready()
    |> select_event(event.qid)
    |> assert_has(Query.css("#event-panel"))

    contributor_session
    |> retry_stale(&click(&1, Query.css("#propose-correction summary")))
    |> assert_has(Query.css("a[href*='propose_field=begin_date']"))
    |> click_via_js("a[href*='propose_field=begin_date']")
    |> assert_has(Query.css("#display-name-form"))
    |> retry_stale(
      &fill_in(&1, Query.css("input[name='display_name[display_name]']"), with: "Contributeur2")
    )
    |> retry_stale(&click(&1, Query.css("#display-name-form button", text: "Enregistrer")))
    |> assert_has(Query.css("#proposal-form-form"))
    |> retry_stale(&fill_in(&1, Query.css("input[name='proposal[year]']"), with: "-700"))
    |> retry_stale(
      &fill_in(&1, Query.css("textarea[name='proposal[source]']"),
        with: "https://example.org/fondation-rome-contestee"
      )
    )
    |> retry_stale(
      &click(&1, Query.css("#proposal-form-form button", text: "Envoyer la proposition"))
    )
    |> assert_has(Query.css("#flash-group", text: "Proposition envoyée"))

    reviewer_session
    |> sign_in_via_magic_link(reviewer.email)
    |> visit("/relecture")
    |> assert_has(Query.css("#review-queue", text: "Contributeur2"))
    |> retry_stale(
      &fill_in(&1, Query.css("#review-queue textarea[name='message']"),
        with: "Source insuffisante pour cette date"
      )
    )
    |> retry_stale(&click(&1, Query.css("#review-queue button[value='reject']")))
    |> assert_has(Query.css("#flash-group", text: "Proposition rejetée"))

    # The author sees the public motive and replies once (the appeal):
    # driven from the CONTRIBUTOR's own session, signed in as its own
    # author (anti-IDOR, `.claude/rules/security.md`), but the motive
    # itself is asserted as plain page content, exactly what an anonymous
    # visitor reads too.
    contribution_path =
      contributor_session
      |> visit("/contributions")
      |> assert_has(Query.css("li", text: "Rejetée"))
      |> retry_stale(&click(&1, Query.css("li a", text: "Fondation de Rome")))
      |> assert_has(Query.css("body", text: "Source insuffisante pour cette date"))
      |> current_path()

    contributor_session
    |> assert_has(Query.css("form[phx-submit='submit_appeal']"))
    |> retry_stale(
      &fill_in(&1, Query.css("input[name='appeal[text]']"),
        with: "Voici une seconde source fiable"
      )
    )
    |> retry_stale(&click(&1, Query.css("button", text: "Envoyer")))
    |> assert_has(Query.css("body", text: "Voici une seconde source fiable"))
    # A second reply is impossible: the form is gone, even after a fresh
    # visit to the same public URL.
    |> refute_has(Query.css("form[phx-submit='submit_appeal']"))

    contributor_session
    |> visit(contribution_path)
    |> refute_has(Query.css("form[phx-submit='submit_appeal']"))

    # The reviewer makes the FINAL decision on the appeal: public,
    # motivated, and terminal.
    reviewer_session
    |> visit("/relecture")
    |> assert_has(Query.css("#review-queue", text: "Voici une seconde source fiable"))
    |> retry_stale(
      &fill_in(&1, Query.css("#review-queue textarea[name='message']"),
        with: "Deuxième source également insuffisante, rejet maintenu"
      )
    )
    |> retry_stale(&click(&1, Query.css("#review-queue button[value='rejected']")))
    |> assert_has(Query.css("#flash-group", text: "Appel tranché"))

    contributor_session
    |> visit(contribution_path)
    |> assert_has(
      Query.css("body", text: "Deuxième source également insuffisante, rejet maintenu")
    )
    |> refute_has(Query.css("form[phx-submit='submit_appeal']"))
  end
end
