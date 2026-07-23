defmodule Amanogawa.Alerting.ErrorReporter do
  @moduledoc """
  Minimal, sober alerting (issue #028, option A): counts `:error`-level
  `Logger` events on a sliding window and sends one mail
  (`Amanogawa.Alerting.Notifier`) when a threshold is crossed, with a
  silence period so a burst never sends more than one mail per period.

  No third-party APM or tracking service (`.claude/rules/ethics.md`, ADR
  0008): this is a `:logger` handler (`log/2` below) backed by a
  `GenServer` that holds the sliding-window state, attached with
  `attach/1` and detached with `detach/1`.

  `Amanogawa.Application` attaches this handler at boot only when
  `config :amanogawa, :start_error_reporter` is true (the default;
  `config/test.exs` sets it to `false` so the test suite's own many
  deliberate `:error` logs, from ingestion's hostile-fixture tests among
  others, never drive a real alert or an unexpected call to a Mox
  notifier the test in question never set up). Tests that specifically
  exercise this module start and attach their own instance with
  `start_supervised!/2` instead.

  The window, threshold, silence period, notifier, and clock are all
  configurable per instance (`start_link/1` options), the last two purely
  for testability (`.claude/rules/testing.md`: inject the clock instead
  of `Process.sleep`ing through real minutes).
  """

  use GenServer

  require Logger

  alias Amanogawa.Alerting.Clock

  @handler_id :amanogawa_error_reporter

  defstruct [
    :window_ms,
    :threshold,
    :silence_ms,
    :notifier,
    :clock,
    timestamps: [],
    silenced_until_ms: nil
  ]

  # -- Public API -------------------------------------------------------

  @doc """
  Starts the counter. Options:

    * `:name` - GenServer name, defaults to `#{inspect(__MODULE__)}`
    * `:window_ms` - sliding window width, defaults to
      `config :amanogawa, Amanogawa.Alerting` (`ALERT_WINDOW_MINUTES`)
    * `:threshold` - error count that triggers a mail, same source
      (`ALERT_ERROR_THRESHOLD`)
    * `:silence_ms` - minimum gap between two mails, same source
      (`ALERT_SILENCE_MINUTES`)
    * `:notifier` - `Amanogawa.Alerting.Notifier` implementation,
      defaults to `Amanogawa.Alerting.Notifier.Mailer`
    * `:clock` - `Amanogawa.Alerting.Clock` implementation, defaults to
      `Amanogawa.Alerting.Clock.System`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    case GenServer.start_link(__MODULE__, opts, name: name) do
      {:ok, _pid} = ok ->
        if Keyword.get(opts, :attach?, true), do: :ok = attach(name)
        ok

      other ->
        other
    end
  end

  @doc "Registers this GenServer as a `:logger` handler for `:error` events."
  @spec attach(GenServer.server()) :: :ok | {:error, term()}
  def attach(server \\ __MODULE__) do
    # `:level` here filters events *before* `log/2` is even invoked
    # (`:logger`'s own primary vs. handler level check): only `:error` and
    # above (there is nothing above `:error` in this codebase's usage)
    # reach this handler at all.
    :logger.add_handler(@handler_id, __MODULE__, %{level: :error, config: server})
  end

  @doc "Unregisters the handler installed by `attach/1`."
  @spec detach() :: :ok | {:error, term()}
  def detach do
    :logger.remove_handler(@handler_id)
  end

  # -- :logger handler callback ------------------------------------------

  # Called synchronously, on the logging process, for every event this
  # handler is registered for (`:logger.add_handler/3`'s own `%{level:
  # :error}` filter set below): must never raise and must never block, so
  # it only ever casts to the counting GenServer and returns immediately.
  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level}, %{config: server})
      when level in [:error, :critical, :alert, :emergency] do
    GenServer.cast(server, :error_logged)
    :ok
  rescue
    _exception -> :ok
  end

  def log(_log_event, _handler_config), do: :ok

  # -- GenServer ----------------------------------------------------------

  @impl true
  def init(opts) do
    defaults = Application.get_env(:amanogawa, Amanogawa.Alerting, [])

    state = %__MODULE__{
      window_ms: Keyword.get(opts, :window_ms, minutes(defaults, :window_minutes, 5)),
      threshold: Keyword.get(opts, :threshold, Keyword.get(defaults, :threshold, 10)),
      silence_ms: Keyword.get(opts, :silence_ms, minutes(defaults, :silence_minutes, 60)),
      notifier: Keyword.get(opts, :notifier, Amanogawa.Alerting.Notifier.Mailer),
      clock: Keyword.get(opts, :clock, Clock.System)
    }

    {:ok, state}
  end

  defp minutes(config, key, default_minutes),
    do: :timer.minutes(Keyword.get(config, key, default_minutes))

  @impl true
  def handle_cast(:error_logged, state) do
    now = state.clock.now_ms()
    timestamps = prune(state.timestamps, now, state.window_ms) ++ [now]

    if trigger?(timestamps, state, now) do
      send_alert(length(timestamps), state)
      {:noreply, %{state | timestamps: [], silenced_until_ms: now + state.silence_ms}}
    else
      {:noreply, %{state | timestamps: timestamps}}
    end
  end

  defp prune(timestamps, now, window_ms) do
    Enum.filter(timestamps, fn ts -> now - ts <= window_ms end)
  end

  defp trigger?(timestamps, state, now) do
    length(timestamps) >= state.threshold and not silenced?(state, now)
  end

  defp silenced?(%{silenced_until_ms: nil}, _now), do: false
  defp silenced?(%{silenced_until_ms: until_ms}, now), do: now < until_ms

  defp send_alert(error_count, state) do
    window_minutes = div(state.window_ms, 60_000)
    subject = "Amanogawa: #{error_count} erreurs en #{window_minutes} min"

    body = """
    #{error_count} evenements de niveau error ont ete journalises sur les \
    #{window_minutes} dernieres minutes, au-dela du seuil de #{state.threshold}.

    Prochaine alerte possible au plus tot dans #{div(state.silence_ms, 60_000)} minutes.

    Consulter les journaux : kamal app logs (docs/ops/deploy.md).
    """

    case state.notifier.deliver(subject, body) do
      :ok ->
        :ok

      {:error, reason} ->
        # Logger.warning, deliberately not Logger.error: this handler only
        # reacts to :error events, and logging the delivery failure at
        # :error would feed straight back into itself (issue #028's own
        # "pas de recursion d'erreur"). The reason is interpolated into the
        # message, not passed as structured metadata, matching every other
        # Logger call in this codebase (config/config.exs's
        # `:default_formatter` only declares `:request_id`).
        Logger.warning(
          "Amanogawa.Alerting.ErrorReporter failed to deliver an alert: #{inspect(reason)}"
        )
    end
  rescue
    exception ->
      Logger.warning(
        "Amanogawa.Alerting.ErrorReporter crashed while delivering an alert: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )
  end
end
