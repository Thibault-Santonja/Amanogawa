defmodule Amanogawa.Contributions.Override do
  @moduledoc """
  One proposed contribution: a correction of an existing event's field
  (`kind: :field`), a new typed relation between two events
  (`kind: :link`), or a brand new event (`kind: :new_event`), issue #034.

  `event_qid` and `author_id` carry no foreign key
  (`.claude/rules/architecture.md`: no FK crosses a PG schema boundary
  between contexts): the referenced event's existence is checked at the
  application layer when a proposal is made
  (`Amanogawa.Contributions.propose/2`), and `author_id` is set to `nil`
  on account anonymization (issue #038) without touching this table.

  ## jsonb payload shapes

  `proposed_value`, `current_value` and `wikidata_value_at_acceptance` are
  plain maps with STRING keys (`changeset/2` normalizes any atom-keyed
  input on cast, so every reader downstream can assume string keys
  whether the map came straight from a form or round-tripped through the
  database), shaped per `field` (for `kind: :field`) or as a whole event
  payload (for `kind: :new_event`):

    * `:label_fr` / `:label_en` - `%{"value" => string}`.
    * `:begin_date` / `:end_date` - `%{"year" => integer, "month" =>
      integer | nil, "day" => integer | nil, "precision" => 0..11,
      "calendar" => "gregorian" | "julian"}`, re-validated by replaying
      `Amanogawa.HistoricalDate.changeset/2` on the payload (the model's
      invariants are defined in exactly one place, `.claude/rules/
      geo-temporal.md`).
    * `:position` - `%{"lon" => float, "lat" => float}` for a proposal
      (`current_value`/`wikidata_value_at_acceptance` additionally carry
      `"location_source"`, the provenance snapshotted from the event),
      bounded to the whole world (`-180..180`, `-90..90`).
    * `kind: :new_event` - `%{"label_fr" => ..., "label_en" => ...,
      "description_fr" => ..., "description_en" => ..., "begin_date" =>
      ..., "position" => ...}` (`description_*` optional, everything else
      required), each nested value shaped as above.

  This module never calls `Amanogawa.Atlas` (an internal schema of
  another context reaching into a peer's internals would itself be a
  boundary violation): `Amanogawa.Atlas.OverridableField` is the mirror
  definition on the Atlas side, kept in sync by hand
  (`Amanogawa.Contributions.record_sync_divergences/1`'s moduledoc
  explains why the two cannot share one module without breaking the
  facade-only contract, `.claude/rules/architecture.md`).

  Internal to the Contributions context: only `Amanogawa.Contributions` is
  called from other contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Amanogawa.HistoricalDate

  @type t :: %__MODULE__{}
  @type kind :: :field | :link | :new_event
  @type status :: :pending | :accepted | :rejected | :superseded | :appealed
  @type field_name :: :label_fr | :label_en | :begin_date | :end_date | :position
  @type link_type :: :part_of | :follows | :cause | :effect | :significant

  @schema_prefix "contributions"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}

  # The closed set of business field names a `:field` override can
  # target. Mirrors `Amanogawa.Atlas.OverridableField`; see the
  # moduledoc for why the two are not shared directly.
  @field_names [:label_fr, :label_en, :begin_date, :end_date, :position]

  # Mirrors `Amanogawa.Atlas.EventLink.link_type/0`, same reasoning.
  @link_types [:part_of, :follows, :cause, :effect, :significant]

  # Mirrors `Amanogawa.Atlas.Event`'s own `@qid_regex` (`Q\d+` or the
  # local `L<uuid hex>` format): a `:link` proposal's `target_qid` must be
  # a syntactically plausible event identifier before this override is
  # ever looked at by a reviewer.
  @qid_regex ~r/\A(Q\d+|L[0-9a-f]{32})\z/

  @source_min_length 5
  @source_max_length 1000
  @label_max_length 500
  @description_max_length 4000

  schema "overrides" do
    field :kind, Ecto.Enum, values: [:field, :link, :new_event]
    field :event_qid, :string
    field :field, Ecto.Enum, values: @field_names
    field :target_qid, :string
    field :link_type, Ecto.Enum, values: @link_types
    field :proposed_value, :map
    field :current_value, :map
    field :wikidata_value_at_acceptance, :map
    field :source, :string

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :rejected, :superseded, :appealed],
      default: :pending

    field :author_id, Ecto.UUID

    timestamps(type: :utc_datetime)
  end

  @doc """
  The closed set of business field names a `:field` override can target
  (also `Amanogawa.Contributions.Conflict`'s own `field` enum values, the
  one place outside this module that needs the list itself rather than
  just validating against it).
  """
  @spec field_names() :: [field_name()]
  def field_names, do: @field_names

  @doc """
  Builds and validates the changeset for a fresh proposal
  (`Amanogawa.Contributions.propose/2`): casts every column, forces
  `status: :pending` (a proposal is never created in any other state),
  validates `source` (#{@source_min_length}-#{@source_max_length}
  characters, mandatory whatever the kind), and validates the
  kind-specific shape (see the moduledoc for the three shapes).
  """
  @spec propose_changeset(t(), map()) :: Ecto.Changeset.t()
  def propose_changeset(override, attrs) do
    override
    |> cast(attrs, [
      :kind,
      :event_qid,
      :field,
      :target_qid,
      :link_type,
      :proposed_value,
      :current_value,
      :source,
      :author_id
    ])
    |> put_change(:status, :pending)
    |> validate_required([:kind, :source])
    |> validate_length(:source, min: @source_min_length, max: @source_max_length)
    |> normalize_payload_keys()
    |> round_position_payload()
    |> validate_kind_shape()
  end

  @doc """
  Builds the changeset `Amanogawa.Contributions.accept_override/3` writes
  through: moves `status` to `:accepted` and stamps
  `wikidata_value_at_acceptance` (the field's value as it stood in
  `atlas.events` at THIS moment, not at proposal time, see the F08
  overview and issue #034's points d'attention). `nil` for a `:link` or
  `:new_event` override, which has no field snapshot to keep.

  Carries the `overrides_one_accepted_per_event_field` unique constraint
  (at most one accepted override per `(event_qid, field)`): a second
  `:field` override for the same event and field accepted after this one
  surfaces as a changeset error rather than a raised
  `Ecto.ConstraintError`.
  """
  @spec accept_changeset(t(), map() | nil) :: Ecto.Changeset.t()
  def accept_changeset(override, wikidata_value_at_acceptance) do
    override
    |> change(status: :accepted)
    |> put_change(
      :wikidata_value_at_acceptance,
      wikidata_value_at_acceptance && stringify(wikidata_value_at_acceptance)
    )
    |> unique_constraint([:event_qid, :field], name: :overrides_one_accepted_per_event_field)
  end

  @doc """
  Builds the changeset that moves a `:pending` override to `:rejected`,
  also reused by `Amanogawa.Contributions.review_appeal/3` for the
  "appeal denied, definitively" outcome (an `:appealed` override moving
  back to `:rejected`): the resulting state is the same terminal
  `:rejected` either way, the caller's own transaction is what decides
  which precondition applied.
  """
  @spec reject_changeset(t()) :: Ecto.Changeset.t()
  def reject_changeset(override), do: change(override, status: :rejected)

  @doc """
  Builds the changeset that moves a `:rejected` override to `:appealed`
  (issue #037, `Amanogawa.Contributions.appeal_override/3`): the author's
  own single reply to a rejection, journalled separately as an
  `:appealed` revision.
  """
  @spec appeal_changeset(t()) :: Ecto.Changeset.t()
  def appeal_changeset(override), do: change(override, status: :appealed)

  @doc """
  Builds the changeset that moves an `:accepted` override to `:superseded`
  (issue #035: Wikidata rejoined the correction, or a reviewer adopted
  Wikidata's value while resolving a conflict).
  """
  @spec supersede_changeset(t()) :: Ecto.Changeset.t()
  def supersede_changeset(override), do: change(override, status: :superseded)

  @doc """
  Builds the changeset that refreshes `wikidata_value_at_acceptance` on an
  `:accepted` override without changing its status (issue #035's
  `resolve_conflict(:keep_override)`: the same divergence must not
  re-signal on the next sync, so the snapshot moves forward to the value
  Wikidata now carries).

  `nil` when Wikidata now carries no value at all for the field (the
  conflict stored the reserved absent marker, see
  `Amanogawa.Contributions.Conflict`): the snapshot moves forward to
  "absent", so the next sync compares `nil` to `nil` and stays silent.
  """
  @spec refresh_snapshot_changeset(t(), map() | nil) :: Ecto.Changeset.t()
  def refresh_snapshot_changeset(override, wikidata_value) do
    change(override, wikidata_value_at_acceptance: stringify(wikidata_value))
  end

  defp normalize_payload_keys(changeset) do
    changeset
    |> update_change(:proposed_value, &stringify/1)
    |> update_change(:current_value, &stringify/1)
  end

  defp stringify(nil), do: nil

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  # Rounds coordinates to 6 decimal digits at PROPOSAL time, symmetrically
  # with `Amanogawa.Contributions`' own snapshot rounding (its
  # `round_coord/1`, ~11cm at the equator): without it, a stored proposed
  # position never compares equal to the sync's rounded incoming value,
  # making the `:superseded` outcome unreachable for `:position` and
  # falsely lighting the review queue's "reference changed" badge.
  defp round_position_payload(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :field)} do
      {:field, :position} ->
        update_change(changeset, :proposed_value, &round_position/1)

      {:new_event, _field} ->
        update_change(changeset, :proposed_value, &round_new_event_position/1)

      _other ->
        changeset
    end
  end

  defp round_position(%{"lon" => lon, "lat" => lat} = payload)
       when is_number(lon) and is_number(lat) do
    %{payload | "lon" => Float.round(lon / 1, 6), "lat" => Float.round(lat / 1, 6)}
  end

  defp round_position(payload), do: payload

  defp round_new_event_position(%{"position" => %{} = position} = payload) do
    %{payload | "position" => round_position(position)}
  end

  defp round_new_event_position(payload), do: payload

  defp validate_kind_shape(changeset) do
    case get_field(changeset, :kind) do
      :field -> validate_field_kind(changeset)
      :link -> validate_link_kind(changeset)
      :new_event -> validate_new_event_kind(changeset)
      _ -> changeset
    end
  end

  defp validate_field_kind(changeset) do
    changeset
    |> validate_required([:event_qid, :field])
    |> validate_format(:event_qid, @qid_regex, message: "must be a valid event id")
    |> validate_field_payload(:proposed_value)
  end

  defp validate_link_kind(changeset) do
    changeset
    |> validate_required([:event_qid, :target_qid, :link_type])
    |> validate_format(:event_qid, @qid_regex, message: "must be a valid event id")
    |> validate_format(:target_qid, @qid_regex, message: "must be a valid event id")
  end

  defp validate_new_event_kind(changeset) do
    changeset
    |> validate_required([:proposed_value])
    |> validate_new_event_payload(:proposed_value)
  end

  # Dispatches on the changeset's OWN `field` value: a `:field` kind
  # override's payload shape depends on which business field it targets,
  # so this cannot be validated independently of it.
  defp validate_field_payload(changeset, payload_field) do
    case {get_field(changeset, :field), get_field(changeset, payload_field)} do
      {nil, _payload} ->
        changeset

      {business_field, payload} ->
        validate_business_field_payload(changeset, payload_field, business_field, payload)
    end
  end

  defp validate_business_field_payload(changeset, payload_field, business_field, payload) do
    case business_field_error(business_field, payload) do
      nil -> changeset
      message -> add_error(changeset, payload_field, message)
    end
  end

  # `end_date` is the one field a proposal may legitimately clear
  # (removing an erroneous end date is a correction in its own right,
  # issue #034's own edge case): every other field requires a value.
  defp business_field_error(:end_date, nil), do: nil
  defp business_field_error(_field, nil), do: "is required"

  defp business_field_error(field, payload) when field in [:label_fr, :label_en],
    do: label_error(payload)

  defp business_field_error(field, payload) when field in [:begin_date, :end_date],
    do: date_error(payload)

  defp business_field_error(:position, payload), do: position_error(payload)

  defp label_error(%{"value" => value}) when is_binary(value) do
    cond do
      String.trim(value) == "" -> "value must not be blank"
      String.length(value) > @label_max_length -> "value is too long (max #{@label_max_length})"
      true -> nil
    end
  end

  defp label_error(_payload), do: "must be %{\"value\" => string}"

  # Requires every key to be present (even as `nil`, `:month`/`:day`
  # legitimately are), the same way `label_error/1` and `position_error/1`
  # do: a payload missing a required key falls through to the catch-all
  # below rather than reaching `Amanogawa.HistoricalDate.changeset/2` with
  # silently-defaulted `nil`s and reporting a confusing nested error.
  defp date_error(%{
         "year" => year,
         "month" => month,
         "day" => day,
         "precision" => precision,
         "calendar" => calendar
       }) do
    if calendar in ["gregorian", "julian", nil] do
      attrs = %{
        year: year,
        month: month,
        day: day,
        precision: precision,
        calendar: calendar_atom(calendar)
      }

      case HistoricalDate.new(attrs) do
        {:ok, _date} -> nil
        {:error, date_changeset} -> "invalid date: #{inspect(errors_on(date_changeset))}"
      end
    else
      # A forged calendar is REJECTED, never coerced to `nil` (security
      # review, calendar finding): coercing would validate the payload as
      # calendar-less, then store the hostile string verbatim in jsonb,
      # where every later replay through `String.to_existing_atom/1`
      # used to crash the public pages and the review queue.
      "calendar must be \"gregorian\" or \"julian\""
    end
  end

  defp date_error(_payload), do: "must be a date payload"

  defp calendar_atom("gregorian"), do: :gregorian
  defp calendar_atom("julian"), do: :julian
  defp calendar_atom(_other), do: nil

  @max_lon 180
  @max_lat 90

  defp position_error(%{"lon" => lon, "lat" => lat}) when is_number(lon) and is_number(lat) do
    if lon >= -@max_lon and lon <= @max_lon and lat >= -@max_lat and lat <= @max_lat do
      nil
    else
      "must be within world bounds"
    end
  end

  defp position_error(_payload), do: "must be %{\"lon\" => number, \"lat\" => number}"

  defp validate_new_event_payload(changeset, payload_field) do
    case get_field(changeset, payload_field) do
      nil -> changeset
      payload -> validate_new_event_payload_map(changeset, payload_field, payload)
    end
  end

  defp validate_new_event_payload_map(changeset, payload_field, payload) do
    errors =
      [
        {"label_fr", &optional_label_error/1},
        {"label_en", &optional_label_error/1},
        {"description_fr", &optional_description_error/1},
        {"description_en", &optional_description_error/1}
      ]
      |> Enum.map(fn {key, validator} -> validator.(Map.get(payload, key)) end)
      |> Enum.reject(&is_nil/1)

    errors = errors ++ new_event_label_presence_errors(payload)
    errors = errors ++ new_event_required_errors(payload)

    Enum.reduce(errors, changeset, &add_error(&2, payload_field, &1))
  end

  defp optional_label_error(nil), do: nil
  defp optional_label_error(value) when is_binary(value), do: label_error(%{"value" => value})
  defp optional_label_error(_value), do: "label must be a string"

  # Optional free text, but bounded (security review, minor 2): a hostile
  # multi-megabyte description must never reach jsonb storage nor, once
  # accepted, `Amanogawa.Atlas.Event`'s own columns (which enforce the
  # same bound in `Amanogawa.Atlas.Event.changeset/2`).
  defp optional_description_error(nil), do: nil

  defp optional_description_error(value) when is_binary(value) do
    if String.length(value) > @description_max_length do
      "description is too long (max #{@description_max_length})"
    end
  end

  defp optional_description_error(_value), do: "description must be a string"

  # `Map.get/2`, not a `%{"label_fr" => fr, "label_en" => en}` pattern:
  # a strict map pattern would require BOTH keys to be present at all
  # (even as `nil`) to match, wrongly rejecting the common case of a
  # payload that only carries the one label the contributor actually
  # filled in.
  defp new_event_label_presence_errors(payload) do
    if is_binary(Map.get(payload, "label_fr")) or is_binary(Map.get(payload, "label_en")) do
      []
    else
      ["label_fr or label_en is required"]
    end
  end

  defp new_event_required_errors(payload) do
    [
      date_field_error(payload, "begin_date"),
      position_field_error(payload, "position")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp date_field_error(payload, key) do
    case Map.get(payload, key) do
      nil -> "#{key} is required"
      value -> wrap_error(key, date_error(value))
    end
  end

  defp position_field_error(payload, key) do
    case Map.get(payload, key) do
      nil -> "#{key} is required"
      value -> wrap_error(key, position_error(value))
    end
  end

  defp wrap_error(_key, nil), do: nil
  defp wrap_error(key, message), do: "#{key} #{message}"

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
