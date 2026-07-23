defmodule Amanogawa.Atlas.TimeScale do
  @moduledoc """
  Symlog time scale shared by the timeline (issue #020) and the map: linear
  near the present, logarithmic toward the deep past, with a pivot around
  the Neolithic (`.claude/rules/geo-temporal.md`, ADR 0005). Converts a
  signed astronomical year (`Amanogawa.HistoricalDate`'s convention, 1 BCE
  is year `0`) to a normalized position in `[0.0, 1.0]` (`0.0` the deepest
  past, `1.0` the present edge of the domain) and back.

  This module is the Elixir half of a two-language contract: the JS mirror
  `assets/js/lib/time_scale.js` implements the exact same formulas, the
  exact same default configuration, and the exact same clamping behavior.
  If the two ever diverge, the histogram (#020, SQL `width_bucket` on this
  scale's position) desynchronizes from the axis the client draws. Both
  sides are tested against the single shared fixture
  `test/support/fixtures/time_scale/anchors.json` (ExUnit here, `node:test`
  on the JS side), tolerance `1.0e-9`.

  ## Formulas (authoritative: mirrored, never re-derived, in the JS module)

  Given a scale with `min_year`, `max_year`, `pivot`:

      t(year) = ln(1 + (max_year - year) / pivot)
      position(year) = 1 - t(year) / t(min_year)
      year(position) = max_year - pivot * (exp((1 - position) * t(min_year)) - 1)

  `t/1` is strictly decreasing as `year` grows (the argument of `ln` shrinks
  toward `1`), so `position/2` is `0.0` at `min_year`, `1.0` at `max_year`,
  and strictly increasing in between: a larger (more recent) year always
  maps to a larger position. `pivot` controls how quickly the scale
  transitions from its logarithmic regime (deep past) to its linear regime
  (near `max_year`): the default, `10_000`, roughly centers that transition
  on the start of the Neolithic.

  ## Default domain: THE time-window domain

  `min_year: -300_000`, `max_year:` the current UTC year (computed at
  runtime, never a hardcoded literal), `pivot: 10_000`: from a comfortable
  margin before the earliest events the corpus (Wikidata-backed
  prehistory) can meaningfully place on a timeline, up to today.
  Deliberately narrower than `Amanogawa.HistoricalDate`'s own
  `[-13_800_000_000, 3_000]` domain (the age of the universe down to
  precision-0 dates): stretching the timeline to cosmological depth would
  collapse everything since the Neolithic into a sliver of pixels,
  defeating the whole point of a symlog scale tuned for human history. A
  caller needing the full `HistoricalDate` domain builds its own
  `%TimeScale{}` via `new/1`.

  `default/0` is the SINGLE server-side source of truth for the time
  window's domain (F04 design decision D1): `AmanogawaWeb.Params.
  ExploreParams` (URL window defaults and validation) and
  `AmanogawaWeb.Params.HistogramQuery` (histogram bounds) both delegate
  their bounds here, and `AmanogawaWeb.ExploreLive` transmits the same
  domain to the client hooks through the `data-domain-min`/
  `data-domain-max` attributes; no other module may duplicate these
  bounds. Because `max_year` is the current year, `default/0` must never
  be captured in a module attribute (that would freeze the build year into
  the release): always call it at runtime.

  ## Clamping, never an exception

  `position/2` and `year/2` clamp out-of-domain input rather than raising:
  a year before `min_year` reports position `0.0`, one after `max_year`
  reports `1.0`; a position outside `[0.0, 1.0]` is clamped the same way
  before conversion. This mirrors how the rest of the project treats
  user-controlled temporal input (`AmanogawaWeb.Params.EventsQuery`,
  `AmanogawaWeb.Params.ExploreParams`: bound, never crash) and keeps the
  timeline hook and the histogram endpoint simple: a window that overshoots
  the domain degrades to the domain edge instead of erroring.

  ## Adaptive ticks and the BP convention

  `ticks/3` returns "round" years for a sub-window, adapted to a target
  tick count. Below the deep-past threshold (astronomical year `<=
  -10_000`), ticks are chosen as round **BP** values (`BP` = years before
  1950, the radiocarbon convention) and
  converted back to astronomical years, preparing the "100 ka BP" labels of
  issue #020's `Amanogawa.Atlas.TimeScale.Format`; above that threshold,
  ticks are chosen as round calendar years (steps of `1, 2, 5 x 10^n`). A
  window straddling the threshold gets ticks from both regimes, merged and
  sorted. The threshold is a fixed convention (`-10_000`), independent of
  a custom scale's `pivot`: it is a display convention, not a scale
  parameter.
  """

  @enforce_keys [:min_year, :max_year, :pivot]
  defstruct [:min_year, :max_year, :pivot]

  @type t :: %__MODULE__{min_year: integer(), max_year: integer(), pivot: pos_integer()}

  @default_min_year -300_000
  @default_pivot 10_000

  # Radiocarbon "before present" epoch: BP = @bp_epoch - year.
  @bp_epoch 1950

  # Fixed display convention (issue #019/#020): below this astronomical
  # year, ticks and axis labels switch to the BP regime. Independent of a
  # custom scale's `pivot`, which is a formula parameter, not a labeling
  # convention.
  @bp_threshold_year -10_000

  @default_tick_count 6

  @doc """
  Builds a validated `%TimeScale{}`. `opts` (a map or keyword list) may
  override `:min_year`, `:max_year`, `:pivot`; every field defaults to the
  module's documented default domain (`max_year` to the current UTC year,
  evaluated when `new/1` is called).

  Returns `{:error, reason}` (a human-readable string) when
  `min_year >= max_year` or `pivot <= 0`, never raises.

  ## Examples

      iex> {:ok, scale} = Amanogawa.Atlas.TimeScale.new()
      iex> {scale.min_year, scale.pivot}
      {-300_000, 10_000}
      iex> scale.max_year == Date.utc_today().year
      true

      iex> Amanogawa.Atlas.TimeScale.new(min_year: 100, max_year: 0)
      {:error, "min_year must be less than max_year"}

  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def new(opts \\ []) do
    attrs = Map.new(opts)
    min_year = Map.get(attrs, :min_year, @default_min_year)
    max_year = Map.get(attrs, :max_year, current_year())
    pivot = Map.get(attrs, :pivot, @default_pivot)

    cond do
      not (min_year < max_year) ->
        {:error, "min_year must be less than max_year"}

      not (pivot > 0) ->
        {:error, "pivot must be a positive integer"}

      true ->
        {:ok, %__MODULE__{min_year: min_year, max_year: max_year, pivot: pivot}}
    end
  end

  @doc "Same as `new/1` but raises `ArgumentError` on invalid input."
  @spec new!(map() | keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, scale} -> scale
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  @doc """
  The default scale (`new!/1` with no overrides): the single server-side
  source of truth for the time-window domain (see the moduledoc). Its
  `max_year` is the current UTC year, so this function must be called at
  runtime, never captured in a module attribute.
  """
  @spec default() :: t()
  def default, do: new!()

  @doc "The current UTC year: the default domain's upper bound."
  @spec current_year() :: integer()
  def current_year, do: Date.utc_today().year

  @doc """
  Maps `year` to its normalized position in `[0.0, 1.0]` on `scale`.
  Out-of-domain years are clamped (see moduledoc), never raise.

  ## Examples

      iex> scale = Amanogawa.Atlas.TimeScale.new!(max_year: 2_100)
      iex> Amanogawa.Atlas.TimeScale.position(scale, 2100)
      1.0
      iex> Amanogawa.Atlas.TimeScale.position(scale, -300_000)
      0.0

  """
  @spec position(t(), integer()) :: float()
  def position(%__MODULE__{} = scale, year) do
    clamped_year = clamp(year, scale.min_year, scale.max_year)
    t_min = t(scale, scale.min_year)
    1 - t(scale, clamped_year) / t_min
  end

  @doc """
  Maps `position` (normalized `[0.0, 1.0]`) back to an astronomical year on
  `scale`, rounded to the nearest integer year. Out-of-range positions are
  clamped first (see moduledoc), never raise.

  ## Examples

      iex> scale = Amanogawa.Atlas.TimeScale.new!(max_year: 2_100)
      iex> Amanogawa.Atlas.TimeScale.year(scale, 1.0)
      2100
      iex> Amanogawa.Atlas.TimeScale.year(scale, 0.0)
      -300000

  """
  @spec year(t(), float()) :: integer()
  def year(%__MODULE__{} = scale, position) do
    clamped_position = clamp(position * 1.0, 0.0, 1.0)
    t_min = t(scale, scale.min_year)
    raw_year = scale.max_year - scale.pivot * (:math.exp((1 - clamped_position) * t_min) - 1)

    raw_year
    |> round()
    |> clamp(scale.min_year, scale.max_year)
  end

  @doc """
  Adaptive tick years for the sub-window `{from, to}` (`from <= to`,
  swapped automatically otherwise), targeting `count` graduations.

  Returns a strictly increasing, duplicate-free list of "round" years,
  contained in `[from, to]` clamped to `scale`'s domain: multiples of
  `1, 2, 5 x 10^n` above the BP threshold (`-10_000`, see moduledoc), round
  BP values below it, merged when the window straddles the threshold. Never
  raises: a degenerate window (`from == to`) yields at most one tick, a
  non-positive `count` is treated as `1`.

  ## Examples

      iex> scale = Amanogawa.Atlas.TimeScale.default()
      iex> Amanogawa.Atlas.TimeScale.ticks(scale, {1700, 2000}, 6)
      [1700, 1750, 1800, 1850, 1900, 1950, 2000]

  """
  @spec ticks(t(), {integer(), integer()}, pos_integer()) :: [integer()]
  def ticks(%__MODULE__{} = scale, {from, to}, count) do
    {from, to} = order(from, to)
    from = clamp(from, scale.min_year, scale.max_year)
    to = clamp(to, scale.min_year, scale.max_year)
    count = max(count, 1)

    cond do
      to <= @bp_threshold_year -> deep_ticks(from, to, count)
      from >= @bp_threshold_year -> recent_ticks(from, to, count)
      true -> split_ticks(from, to, count)
    end
  end

  @doc "The fixed astronomical-year threshold below which ticks use the BP convention."
  @spec bp_threshold_year() :: integer()
  def bp_threshold_year, do: @bp_threshold_year

  @doc "The radiocarbon BP epoch (1950): `BP = #{@bp_epoch} - year`."
  @spec bp_epoch() :: integer()
  def bp_epoch, do: @bp_epoch

  @doc "The default target tick count used by callers that do not pick their own."
  @spec default_tick_count() :: pos_integer()
  def default_tick_count, do: @default_tick_count

  defp t(%__MODULE__{max_year: max_year, pivot: pivot}, year) do
    :math.log(1 + (max_year - year) / pivot)
  end

  defp order(from, to) when from <= to, do: {from, to}
  defp order(from, to), do: {to, from}

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp split_ticks(from, to, count) do
    deep_span = @bp_threshold_year - from
    recent_span = to - @bp_threshold_year
    total_span = deep_span + recent_span

    deep_count = max(round(count * deep_span / total_span), 1)
    recent_count = max(count - deep_count, 1)

    deep = deep_ticks(from, @bp_threshold_year, deep_count)
    recent = recent_ticks(@bp_threshold_year, to, recent_count)

    (deep ++ recent) |> Enum.uniq() |> Enum.sort()
  end

  # BP grows as the (astronomical, negative) year shrinks: `bp_high`
  # (oldest, from `from`) down to `bp_low` (closest to present, from `to`).
  # Round BP values are generated ascending from `bp_low` to `bp_high`, then
  # mapped back to years and sorted ascending, so the final tick order is
  # always chronological regardless of the BP/year inversion.
  defp deep_ticks(from, to, count) do
    bp_high = @bp_epoch - from
    bp_low = @bp_epoch - to
    step = nice_step(bp_high - bp_low, count)

    bp_low
    |> ceil_to_step(step)
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= bp_high))
    |> Enum.map(&(@bp_epoch - &1))
    |> Enum.sort()
  end

  defp recent_ticks(from, to, count) do
    step = nice_step(to - from, count)

    from
    |> ceil_to_step(step)
    |> Stream.iterate(&(&1 + step))
    |> Enum.take_while(&(&1 <= to))
    |> Enum.to_list()
  end

  # Chooses a "round" step (1, 2, 5, or 10 times a power of ten) so that
  # `range / step` is close to `target_count`, floored at 1 (years are
  # integers, sub-year ticks make no sense on this scale).
  defp nice_step(range, target_count) do
    target_count = max(target_count, 1)
    raw_step = range / target_count

    if raw_step <= 1 do
      1
    else
      magnitude = :math.pow(10, Float.floor(:math.log10(raw_step)))
      residual = raw_step / magnitude

      nice =
        cond do
          residual <= 1 -> 1
          residual <= 2 -> 2
          residual <= 5 -> 5
          true -> 10
        end

      nice |> Kernel.*(magnitude) |> round() |> max(1)
    end
  end

  # Smallest multiple of `step` greater than or equal to `value`.
  defp ceil_to_step(value, step) do
    (value / step) |> Float.ceil() |> Kernel.*(step) |> round()
  end
end
