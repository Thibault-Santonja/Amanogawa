defmodule AmanogawaWeb.LoginLiveTest do
  use AmanogawaWeb.ConnCase, async: false

  import Amanogawa.AccountsFixtures
  import Mox
  import Phoenix.LiveViewTest

  alias Amanogawa.MagicLinkNotifierMock

  # Global mode: LoginLive's `handle_event` runs `Accounts.deliver_magic_link/4`
  # inside the LiveView process, distinct from the test process that sets
  # up expectations (same rationale as `HealthControllerTest`).
  setup :set_mox_global
  setup :verify_on_exit!

  describe "mount" do
    test "renders the email form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/connexion")

      assert html =~ "Connexion"
      assert has_element?(lv, "#login-form")
      refute has_element?(lv, "#magic-link-sent")
    end

    test "an already-authenticated visitor is redirected to /", %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, ~p"/connexion")
    end

    test "a known ?locale= query param is honored for the magic link URL's own locale", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/connexion?locale=en")
      email = unique_email()

      expect(MagicLinkNotifierMock, :deliver, fn _email, _url, locale ->
        assert locale == "en"
        :ok
      end)

      lv |> form("#login-form", login: %{email: email}) |> render_submit()
    end
  end

  describe "send_magic_link: happy path" do
    test "submitting a valid email shows the check-your-inbox state and sends one email", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/connexion")
      email = unique_email()

      expect(MagicLinkNotifierMock, :deliver, fn received_email, _url, _locale ->
        assert received_email == email
        :ok
      end)

      html =
        lv
        |> form("#login-form", login: %{email: email})
        |> render_submit()

      assert html =~ "Vérifiez votre boîte mail"
      assert has_element?(lv, "#magic-link-sent")
      refute has_element?(lv, "#login-form")
    end
  end

  describe "send_magic_link: edge case anti-enumeration" do
    test "a known and an unknown email render the exact same state", %{conn: conn} do
      known = user_fixture()

      expect(MagicLinkNotifierMock, :deliver, 2, fn _email, _url, _locale -> :ok end)

      {:ok, known_lv, _html} = live(conn, ~p"/connexion")

      known_html =
        known_lv
        |> form("#login-form", login: %{email: known.email})
        |> render_submit()

      {:ok, unknown_lv, _html} = live(build_conn(), ~p"/connexion")

      unknown_html =
        unknown_lv
        |> form("#login-form", login: %{email: unique_email()})
        |> render_submit()

      # Two positive, separate assertions: both journeys must actually
      # reach the confirmation state (a comparative `a == b` assertion
      # would also pass when NEITHER html contained the message).
      assert known_html =~ "Vérifiez votre boîte mail"
      assert unknown_html =~ "Vérifiez votre boîte mail"
    end
  end

  describe "send_magic_link: error case invalid email" do
    test "a malformed email reshows the form with a validation error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/connexion")

      html =
        lv
        |> form("#login-form", login: %{email: "sans-arobase"})
        |> render_submit()

      assert html =~ "doit être une adresse email valide"
      assert has_element?(lv, "#login-form")
      refute has_element?(lv, "#magic-link-sent")
    end
  end

  describe "send_magic_link: limit case rate limited" do
    test "exhausting the quota shows the dedicated rate-limit message", %{conn: conn} do
      original = Application.get_env(:amanogawa, Amanogawa.Accounts.MagicLinkThrottle, [])

      Application.put_env(:amanogawa, Amanogawa.Accounts.MagicLinkThrottle,
        limit: 1,
        scale_ms: :timer.minutes(15)
      )

      on_exit(fn ->
        Application.put_env(:amanogawa, Amanogawa.Accounts.MagicLinkThrottle, original)
      end)

      # Its own fake peer IP (mirrors AmanogawaWeb.ExploreLiveTest's own
      # `unique_ip/0` + `Plug.Test.put_peer_data/2`): the IP throttle
      # counter is a single, shared, process-wide Hammer table, not reset
      # between tests, so a lowered quota of 1 must not collide with
      # every other test in this module sharing the default 127.0.0.1
      # peer.
      conn = put_peer_ip(conn, unique_ip())
      email = unique_email()
      expect(MagicLinkNotifierMock, :deliver, fn _email, _url, _locale -> :ok end)

      {:ok, lv, _html} = live(conn, ~p"/connexion")
      lv |> form("#login-form", login: %{email: email}) |> render_submit()

      {:ok, lv2, _html} = live(conn, ~p"/connexion")

      html =
        lv2
        |> form("#login-form", login: %{email: email})
        |> render_submit()

      assert html =~ "Trop de demandes"
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
