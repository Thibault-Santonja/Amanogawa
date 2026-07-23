defmodule AmanogawaWeb.Params.HistogramQuery do
  @moduledoc """
  Parses and validates the raw query parameters of
  `GET /api/events/histogram` (`from`, `to`, `buckets`) into the normalized
  options expected by `Amanogawa.Atlas.event_histogram/1` (issue #020).

  Unlike `AmanogawaWeb.Params.EventsQuery` (which defaults an absent
  `from`/`to` to the full supported range), every parameter here is
  required and strictly validated: `.claude/rules/security.md` and issue
  #020 both call for "validation stricte: tout paramètre invalide retourne
  422, jamais de valeur silencieusement corrigée" for this endpoint. A
  caller building a histogram request always knows the window it wants
  (the timeline hook derives it from its own rendered domain); silently
  falling back to a default window here would hide a client bug instead of
  surfacing it as a 422.

  `from`/`to` are bounded to `Amanogawa.Atlas.TimeScale.default/0`'s domain
  (`[-300_000, 2_100]`), not `Amanogawa.HistoricalDate`'s much wider one:
  the histogram's bucket edges are computed on that scale
  (`Amanogawa.Atlas.EventQueries.histogram_counts/1`), so a window outside
  it can never be served meaningfully.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Amanogawa.Atlas.TimeScale

  @type normalized :: %{from: integer(), to: integer(), buckets: pos_integer()}

  @scale TimeScale.default()
  @min_year @scale.min_year
  @max_year @scale.max_year

  @default_buckets 100
  @max_buckets 200

  @primary_key false
  embedded_schema do
    field :from, :integer
    field :to, :integer
    field :buckets, :integer, default: @default_buckets
  end

  @doc """
  Parses raw query params (string-keyed, as received in `conn.params`) into
  normalized options.

  Returns `{:ok, normalized}` or `{:error, errors}`, `errors` being
  `%{field => [message]}`, exactly like `AmanogawaWeb.Params.EventsQuery.
  parse/1`.
  """
  @spec parse(map()) :: {:ok, normalized()} | {:error, %{atom() => [String.t()]}}
  def parse(params) when is_map(params) do
    changeset = changeset(params)

    if changeset.valid? do
      {:ok, normalize(changeset)}
    else
      {:error, errors(changeset)}
    end
  end

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(params) do
    %__MODULE__{}
    |> cast(params, [:from, :to, :buckets])
    |> validate_required([:from, :to])
    |> validate_year(:from)
    |> validate_year(:to)
    |> validate_from_before_to()
    |> validate_number(:buckets,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_buckets
    )
  end

  defp validate_year(changeset, field) do
    validate_number(changeset, field,
      greater_than_or_equal_to: @min_year,
      less_than_or_equal_to: @max_year
    )
  end

  # Strictly less than, unlike `EventsQuery`'s `from <= to`: a
  # zero-width window has no meaningful bucket to divide it into.
  defp validate_from_before_to(changeset) do
    case {get_field(changeset, :from), get_field(changeset, :to)} do
      {from, to} when is_integer(from) and is_integer(to) and from >= to ->
        add_error(changeset, :from, "must be less than to")

      _other ->
        changeset
    end
  end

  defp normalize(changeset) do
    %{
      from: get_field(changeset, :from),
      to: get_field(changeset, :to),
      buckets: get_field(changeset, :buckets) || @default_buckets
    }
  end

  defp errors(changeset) do
    traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
