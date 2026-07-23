defmodule Amanogawa.Alerting.ErrorReporterTest do
  # Attaches/detaches a real, global `:logger` handler (issue #028):
  # cannot run concurrently with itself or anything else that touches
  # `:logger`'s handler table.
  use ExUnit.Case, async: false

  import Mox

  require Logger

  alias Amanogawa.Alerting.ClockMock
  alias Amanogawa.Alerting.ErrorReporter
  alias Amanogawa.Alerting.NotifierMock

  setup :set_mox_global
  setup :verify_on_exit!

  # A controllable, non-time-based clock (`.claude/rules/testing.md`: no
  # `Process.sleep` through real windows): each test advances it by
  # calling `advance/1` directly, no real time passes.
  defp start_clock(initial_ms \\ 0) do
    {:ok, agent} = Agent.start_link(fn -> initial_ms end)
    agent
  end

  defp advance(agent, delta_ms), do: Agent.update(agent, &(&1 + delta_ms))
  defp now_fn(agent), do: fn -> Agent.get(agent, & &1) end

  defp start_reporter(opts) do
    {clock_agent, opts} = Keyword.pop!(opts, :clock_agent)
    stub(ClockMock, :now_ms, now_fn(clock_agent))

    name = :"error_reporter_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, notifier: NotifierMock, clock: ClockMock], opts)

    pid = start_supervised!({ErrorReporter, opts}, id: name)
    on_exit(fn -> ErrorReporter.detach() end)
    {pid, name}
  end

  # `Logger.error/1` dispatches to the handler (hence `GenServer.cast/2`)
  # synchronously from the calling (test) process, but the cast itself is
  # asynchronous: `:sys.get_state/1` forces a round trip through the
  # GenServer's mailbox, which (Erlang's FIFO delivery between any two
  # given processes) only returns once every cast sent before it from
  # this same test process has already been handled.
  defp sync(name), do: :sys.get_state(GenServer.whereis(name))

  describe "happy path" do
    test "N errors within the window trigger exactly one mail" do
      clock = start_clock()

      expect(NotifierMock, :deliver, fn subject, body ->
        assert subject =~ "5"
        assert body =~ "5"
        :ok
      end)

      {_pid, name} =
        start_reporter(clock_agent: clock, threshold: 5, window_ms: 60_000, silence_ms: 3_600_000)

      for _ <- 1..5, do: Logger.error("boom")
      sync(name)

      # verify_on_exit! confirms the mock got exactly one call.
    end
  end

  describe "edge case" do
    test "N-1 errors never trigger a mail" do
      clock = start_clock()

      {_pid, name} =
        start_reporter(clock_agent: clock, threshold: 5, window_ms: 60_000, silence_ms: 3_600_000)

      for _ <- 1..4, do: Logger.error("almost")
      sync(name)

      # No expectation set on NotifierMock at all: verify_on_exit! fails
      # the test if any call happened.
    end

    test "errors outside the sliding window no longer count" do
      clock = start_clock()

      {_pid, name} =
        start_reporter(clock_agent: clock, threshold: 5, window_ms: 1_000, silence_ms: 3_600_000)

      for _ <- 1..4, do: Logger.error("early burst")
      # Synchronize before advancing the clock: the GenServer reads the
      # clock when it *processes* each cast, not when it was sent, so the
      # 4 "early" casts must be fully handled (and their timestamps
      # recorded under the old clock value) before time moves forward.
      sync(name)
      advance(clock, 2_000)
      Logger.error("late, alone")
      sync(name)

      # Only 1 error remains in the window (the 4 early ones aged out):
      # nowhere near the threshold of 5, no mail expected.
    end
  end

  describe "error case: notifier failure" do
    test "a delivery failure is captured, never crashes the handler, never recurses" do
      clock = start_clock()

      expect(NotifierMock, :deliver, fn _subject, _body -> raise "SMTP exploded" end)

      {_pid, name} =
        start_reporter(clock_agent: clock, threshold: 2, window_ms: 60_000, silence_ms: 3_600_000)

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          for _ <- 1..2, do: Logger.error("boom")
          sync(name)
        end)

      assert log =~ "failed to deliver" or log =~ "crashed while delivering"
    end
  end

  describe "limit case: silence period" do
    test "repeated bursts during the silence period send at most one mail, then reopen" do
      clock = start_clock()

      expect(NotifierMock, :deliver, fn _subject, _body -> :ok end)

      {_pid, name} =
        start_reporter(clock_agent: clock, threshold: 3, window_ms: 60_000, silence_ms: 10_000)

      for _ <- 1..3, do: Logger.error("first burst")
      sync(name)
      # Still inside the silence period: this second burst must not send.
      advance(clock, 1_000)
      for _ <- 1..5, do: Logger.error("second burst, silenced")
      sync(name)

      # verify_on_exit! confirms exactly one call so far (the `expect`
      # above allows exactly one). Advance past the silence period and
      # confirm the counter reopened: a fresh expectation must be
      # consumed by a fresh burst.
      advance(clock, 10_000)
      expect(NotifierMock, :deliver, fn _subject, _body -> :ok end)
      for _ <- 1..3, do: Logger.error("third burst, after silence")
      sync(name)
    end
  end
end
