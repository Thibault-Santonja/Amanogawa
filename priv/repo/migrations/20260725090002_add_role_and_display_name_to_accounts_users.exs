defmodule Amanogawa.Repo.Migrations.AddRoleAndDisplayNameToAccountsUsers do
  use Ecto.Migration

  @moduledoc """
  Adds the two columns the collaborative editor needs on `accounts.users`
  (issue #034):

    * `role` (`:user` | `:reviewer`, default `:user`): a reviewer is
      promoted manually in the database for V1 (F08 overview's "promue
      manuellement en base pour commencer"), no self-service escalation
      path exists.
    * `display_name` (nullable, unique case-insensitively): the public
      pseudonym required before a user's first proposal
      (`Amanogawa.Accounts.set_display_name/2`), so public attribution
      never leaks an email address.

  The unique index is on `lower(display_name)`, the same technique
  `20260724055313_create_accounts_schema_and_tables.exs` uses for
  `email`: case-insensitive uniqueness without the `citext` extension.
  """

  def change do
    alter table(:users, prefix: "accounts") do
      add :role, :string, null: false, default: "user"
      add :display_name, :string
    end

    create unique_index(:users, ["lower(display_name)"],
             name: :users_display_name_lower_index,
             prefix: "accounts"
           )
  end
end
