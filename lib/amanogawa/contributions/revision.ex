defmodule Amanogawa.Contributions.Revision do
  @moduledoc """
  One entry of an override's append-only public history (issue #034, F08
  overview's "historique intégralement public, daté, attribué"): one row
  per action taken on an `Amanogawa.Contributions.Override`.

  Append-only is a property of `Amanogawa.Contributions`' public API, not
  of the database: this module deliberately exposes no update or delete
  changeset, and the facade exposes no function that would call one (a
  fact `test/amanogawa/contributions_test.exs` verifies by introspecting
  the facade's exported functions). `inserted_at` is the only timestamp
  (no `updated_at`): a revision is never edited after it is written.

  `override_id` carries a foreign key (both tables live in the
  `contributions` PG schema, an intra-context reference is allowed,
  `.claude/rules/architecture.md`); `actor_id` does not (set to `nil` on
  account anonymization, issue #038, without touching this table).

  `message` is the only free text a revision carries (a decision's public
  motive, an appeal's text): it must never hold personal data (email,
  IP), since every revision is public by destination.

  Internal to the Contributions context: only `Amanogawa.Contributions` is
  called from other contexts or from the web layer.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @type action ::
          :proposed
          | :accepted
          | :rejected
          | :appealed
          | :appeal_reviewed
          | :superseded
          | :conflict_resolved
          | :anonymized

  @schema_prefix "contributions"
  @primary_key {:id, Ecto.UUID, autogenerate: [version: 7]}
  @foreign_key_type :binary_id

  # The base seven come from issue #034's own vocabulary; :conflict_resolved
  # was added in issue #035 for `Amanogawa.Contributions.resolve_conflict/3`'s
  # `:kept_override` outcome (the override's OWN status does not change
  # there, unlike `:adopted_wikidata`, which reuses :superseded since that
  # is genuinely what happens to the override in that case).
  @actions [
    :proposed,
    :accepted,
    :rejected,
    :appealed,
    :appeal_reviewed,
    :superseded,
    :conflict_resolved,
    :anonymized
  ]
  @message_max_length 1000

  schema "revisions" do
    belongs_to :override, Amanogawa.Contributions.Override
    field :action, Ecto.Enum, values: @actions
    field :actor_id, Ecto.UUID
    field :message, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Builds and validates the changeset for a fresh revision (the only way
  this schema is ever written, always inside the same transaction as the
  override mutation it journals, `Amanogawa.Contributions`'s facade
  functions).
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(revision, attrs) do
    revision
    |> cast(attrs, [:override_id, :action, :actor_id, :message])
    |> validate_required([:override_id, :action])
    |> validate_length(:message, max: @message_max_length)
    |> foreign_key_constraint(:override_id)
  end
end
