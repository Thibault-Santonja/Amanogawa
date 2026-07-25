defmodule Amanogawa.Repo.Migrations.CreateContributionsSchemaAndTables do
  use Ecto.Migration

  @moduledoc """
  Creates the `contributions` PostgreSQL schema and its three tables (issue
  #034, the fourth and last bounded context, `.claude/rules/architecture.md`):
  `overrides` (one row per proposed correction, addition, or new event),
  `revisions` (append-only history of every action taken on an override) and
  `conflicts` (divergences the monthly sync detects against an accepted
  override, examined in #035).

  On the model of `20260724055313_create_accounts_schema_and_tables.exs`:
  the schema arrives with its context, `up`/`down` rather than `change`
  since schema creation/drop is not reversible by Ecto's DDL inference.

  No foreign key crosses into `atlas` or `accounts`: `event_qid` and
  `author_id` are plain references without a database constraint (F08
  overview's "aucune FK entre schémas PG de contextes différents"), the
  event's existence being checked at the application layer when a
  proposal is made. `revisions.override_id` and `conflicts.override_id`
  DO carry a foreign key: both tables live in the same `contributions`
  schema as `overrides`, so an intra-context FK is allowed.
  """

  def up do
    execute "CREATE SCHEMA IF NOT EXISTS contributions"

    create table(:overrides, primary_key: false, prefix: "contributions") do
      add :id, :binary_id, primary_key: true

      # :field (correct an existing event's field), :link (add a typed
      # relation), :new_event (propose a brand new event).
      add :kind, :string, null: false

      # The corrected/linked-from event, `nil` for a :new_event proposal
      # (there is no existing event yet).
      add :event_qid, :string

      # :field kind only: one of the closed field names
      # (`Amanogawa.Contributions.Override.field_names/0`).
      add :field, :string

      # :link kind only.
      add :target_qid, :string
      add :link_type, :string

      # :field kind: the corrected value. :new_event kind: the full
      # proposed event payload. :link kind: unused (target_qid/link_type
      # carry the whole proposal).
      add :proposed_value, :map

      # :field kind only: the value in place at the moment of proposal
      # (review-time diff).
      add :current_value, :map

      # :field kind only: the Wikidata value snapshotted at ACCEPTANCE
      # time (not at proposal time, see moduledoc of
      # `Amanogawa.Contributions`), the anchor #035's divergence detection
      # compares every later sync against.
      add :wikidata_value_at_acceptance, :map

      # Justification: a source URL or a textual reference. Mandatory,
      # bounded (`Amanogawa.Contributions.Override.changeset/2`).
      add :source, :text, null: false

      add :status, :string, null: false, default: "pending"

      # No foreign key to `accounts.users` on purpose (see moduledoc):
      # anonymization on account deletion (#038) sets this to `nil`
      # without touching `contributions` at all.
      add :author_id, :binary_id

      timestamps(type: :utc_datetime)
    end

    create index(:overrides, [:event_qid], prefix: "contributions")
    create index(:overrides, [:author_id], prefix: "contributions")
    create index(:overrides, [:status, :inserted_at], prefix: "contributions")

    # At most one accepted override per (event, field): the invariant
    # `Amanogawa.Atlas.apply_field_override/3` and the read model both
    # depend on ("the displayed value is the accepted override, or
    # Wikidata's").
    create unique_index(:overrides, [:event_qid, :field],
             where: "status = 'accepted' AND kind = 'field'",
             name: :overrides_one_accepted_per_event_field,
             prefix: "contributions"
           )

    create table(:revisions, primary_key: false, prefix: "contributions") do
      add :id, :binary_id, primary_key: true

      add :override_id,
          references(:overrides, type: :binary_id, prefix: "contributions", on_delete: :nothing),
          null: false

      # :proposed, :accepted, :rejected, :appealed, :appeal_reviewed,
      # :superseded, :anonymized.
      add :action, :string, null: false

      # `nil` once the actor's account is anonymized (#038); never
      # foreign-keyed, same reasoning as `overrides.author_id`.
      add :actor_id, :binary_id

      # Public motive (a decision's reason, an appeal's text). Never
      # personal data (email, IP): the schema itself carries nothing that
      # could hold one, only a bounded text field
      # (`Amanogawa.Contributions.Revision.changeset/2`).
      add :message, :text

      add :inserted_at, :utc_datetime, null: false
    end

    create index(:revisions, [:override_id, :inserted_at], prefix: "contributions")

    create table(:conflicts, primary_key: false, prefix: "contributions") do
      add :id, :binary_id, primary_key: true

      add :override_id,
          references(:overrides, type: :binary_id, prefix: "contributions", on_delete: :nothing),
          null: false

      add :event_qid, :string, null: false
      add :field, :string, null: false

      # The divergent value Wikidata's sync brought in, normalized the
      # same way as `overrides.proposed_value`.
      add :wikidata_value, :map, null: false

      add :detected_at, :utc_datetime, null: false
      add :status, :string, null: false, default: "open"

      # :kept_override or :adopted_wikidata, set by `resolve_conflict/3`.
      add :resolution, :string
      add :resolved_by, :binary_id
      add :resolved_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:conflicts, [:event_qid], prefix: "contributions")

    # At most one OPEN conflict per override: a repeated sync divergence on
    # the same field refreshes this single row (`wikidata_value`,
    # `detected_at`) instead of piling up duplicates.
    create unique_index(:conflicts, [:override_id],
             where: "status = 'open'",
             name: :conflicts_one_open_per_override,
             prefix: "contributions"
           )
  end

  def down do
    drop table(:conflicts, prefix: "contributions")
    drop table(:revisions, prefix: "contributions")
    drop table(:overrides, prefix: "contributions")

    execute "DROP SCHEMA IF EXISTS contributions"
  end
end
