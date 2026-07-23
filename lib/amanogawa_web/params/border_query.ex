defmodule AmanogawaWeb.Params.BorderQuery do
  @moduledoc """
  Parses and validates the raw query parameters of `GET /api/borders`
  (`year`) into the normalized options expected by
  `Amanogawa.Atlas.list_borders_geojson/1` (issue #025).

  Unlike `AmanogawaWeb.Params.EventsQuery`'s `from`/`to` (rejected with a
  `400` when out of the supported domain), an out-of-range `year` here is
  clamped, not rejected (issue #025's own task list): the map's reference
  year is always the upper bound of the timeline window
  (`AmanogawaWeb.ExploreLive`'s moduledoc, F05 design), which legitimately
  ranges far outside the border data's own domain (events go back to
  -13,800,000,000; borders only exist for `[#{-123_000}, #{2024}]`,
  `.claude/memory/data-sources.md`), and a slider sitting anywhere in that
  much larger event domain must always get a sensible answer instead of
  bouncing off a 400.

  `year` itself is still required and must be a plain integer: absent,
  non-integer, or non-numeric input is a genuine caller error (`400`,
  `.claude/rules/security.md`: every user-controlled input is validated),
  not something to guess a default for.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type normalized :: %{year: integer()}

  # The combined domain of the imported border sources (ADR 0004): Cliopatria
  # covers [-3400, 2024], historical-basemaps extends the lower bound back to
  # -123000. Kept here (not re-derived from the database) since it describes
  # what the *sources* can ever contain, not a fact that changes per import.
  @min_year -123_000
  @max_year 2024

  @primary_key false
  embedded_schema do
    field :year, :integer
  end

  @doc """
  Parses raw query params (string-keyed, as received in `conn.params`) into
  `%{year: integer}`, `year` clamped to `[#{@min_year}, #{@max_year}]`.

  Returns `{:ok, normalized}` or `{:error, errors}`, `errors` being
  `%{field => [message]}`.
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
    |> cast(params, [:year])
    |> validate_required([:year])
  end

  defp normalize(changeset) do
    %{year: changeset |> get_field(:year) |> clamp()}
  end

  defp clamp(year) when year < @min_year, do: @min_year
  defp clamp(year) when year > @max_year, do: @max_year
  defp clamp(year), do: year

  # Unlike `AmanogawaWeb.Params.EventsQuery.errors/1`, no validation here
  # ever produces an interpolated message (`cast/3`'s "is invalid" and
  # `validate_required/2`'s "can't be blank" are both plain strings: `year`
  # is clamped rather than range-validated, so there is no `validate_number`
  # `%{count}`/`%{number}` placeholder to resolve): the message is returned
  # as-is, with no `%{...}` substitution step that could never fire.
  defp errors(changeset) do
    traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
