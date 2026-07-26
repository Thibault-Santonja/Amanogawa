defmodule Amanogawa.ContributionsFixtures do
  @moduledoc """
  Canonical builder for Contributions test fixtures. The only place in the
  test suite allowed to construct `Amanogawa.Contributions.Override` /
  `Revision` / `Conflict` rows directly (bypassing
  `Amanogawa.Contributions`' own facade functions, which is what
  `contributions_test.exs` exercises); every other test goes through
  `override_fixture/1`, `accepted_override_fixture/1`, `revision_fixture/1`
  and `conflict_fixture/1`.
  """

  import Amanogawa.AccountsFixtures, only: [user_fixture: 0]
  import Amanogawa.AtlasFixtures, only: [event_fixture: 0]

  alias Amanogawa.Contributions.Conflict
  alias Amanogawa.Contributions.Override
  alias Amanogawa.Contributions.Revision
  alias Amanogawa.Repo

  @doc """
  Inserts a valid `:pending` `:field` override (defaults to a `label_fr`
  correction on a fresh event), overridable via `attrs`.
  """
  @spec override_fixture(map() | keyword()) :: Override.t()
  def override_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    default_attrs = %{
      kind: :field,
      event_qid: fetch_event_qid(attrs),
      field: :label_fr,
      proposed_value: %{"value" => "Nouveau libelle"},
      current_value: %{"value" => "Ancien libelle"},
      source: "https://example.org/source-historique",
      author_id: unique_author_id(attrs)
    }

    %Override{}
    |> Override.propose_changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end

  @doc """
  Inserts an `:accepted` override (a plain field update after
  `override_fixture/1`, bypassing `Amanogawa.Contributions.
  accept_override/3`): `attrs.wikidata_value_at_acceptance` defaults to the
  same value as `current_value` (the common "nothing has diverged yet"
  starting point).
  """
  @spec accepted_override_fixture(map() | keyword()) :: Override.t()
  def accepted_override_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {wikidata_value, attrs} = Map.pop(attrs, :wikidata_value_at_acceptance)

    override = override_fixture(attrs)
    wikidata_value = wikidata_value || override.current_value

    override
    |> Ecto.Changeset.change(status: :accepted, wikidata_value_at_acceptance: wikidata_value)
    |> Repo.update!()
  end

  @doc """
  Inserts a revision row directly (defaults to a `:proposed` revision of a
  freshly built override), overridable via `attrs`.
  """
  @spec revision_fixture(map() | keyword()) :: Revision.t()
  def revision_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {override_id, attrs} = Map.pop_lazy(attrs, :override_id, fn -> override_fixture().id end)

    default_attrs = %{override_id: override_id, action: :proposed}

    %Revision{}
    |> Revision.create_changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end

  @doc """
  Inserts an open conflict (defaults to referencing a freshly accepted
  override), overridable via `attrs`.
  """
  @spec conflict_fixture(map() | keyword()) :: Conflict.t()
  def conflict_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {override, attrs} = Map.pop_lazy(attrs, :override, fn -> accepted_override_fixture() end)

    default_attrs = %{
      override_id: override.id,
      event_qid: override.event_qid,
      field: override.field,
      wikidata_value: %{"value" => "Valeur Wikidata divergente"},
      detected_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    %Conflict{}
    |> Conflict.open_changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end

  defp fetch_event_qid(%{event_qid: qid}), do: qid
  defp fetch_event_qid(_attrs), do: event_fixture().qid

  defp unique_author_id(%{author_id: id}), do: id
  defp unique_author_id(_attrs), do: user_fixture().id
end
