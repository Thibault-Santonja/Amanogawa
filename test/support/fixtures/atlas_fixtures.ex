defmodule Amanogawa.AtlasFixtures do
  @moduledoc """
  Canonical builder for Atlas test fixtures. The only place in the test
  suite allowed to construct `Amanogawa.Atlas.Event` / `EventLink` rows
  directly; every other test goes through `event_fixture/1` and
  `event_link_fixture/1`.
  """

  alias Amanogawa.Atlas.Event
  alias Amanogawa.Atlas.EventLink
  alias Amanogawa.Repo

  @doc """
  Inserts a valid event (defaults to the Battle of Marathon, Q31900, a
  BCE date known to the day), overridable via `attrs`.
  """
  @spec event_fixture(map() | keyword()) :: Event.t()
  def event_fixture(attrs \\ %{}) do
    default_attrs = %{
      qid: unique_qid(),
      label_fr: "Bataille de Marathon",
      label_en: "Battle of Marathon",
      kind: "Q178561",
      begin_year: -489,
      begin_month: 9,
      begin_day: 12,
      begin_precision: 11,
      begin_calendar: :julian,
      geom: %Geo.Point{coordinates: {23.9750, 38.1128}, srid: 4326},
      location_source: :direct,
      sitelink_count: 42
    }

    %Event{}
    |> Event.changeset(Map.merge(default_attrs, Map.new(attrs)))
    |> Repo.insert!()
  end

  @doc """
  Inserts a valid event link. `:source_id`/`:target_id` default to two
  freshly built events when not given in `attrs`.
  """
  @spec event_link_fixture(map() | keyword()) :: EventLink.t()
  def event_link_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {source_id, attrs} = pop_endpoint_id(attrs, :source_id)
    {target_id, attrs} = pop_endpoint_id(attrs, :target_id)

    default_attrs = %{source_id: source_id, target_id: target_id, type: :part_of}

    %EventLink{}
    |> EventLink.changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end

  defp pop_endpoint_id(attrs, key) do
    case Map.pop(attrs, key) do
      {nil, attrs} -> {event_fixture().id, attrs}
      {id, attrs} -> {id, attrs}
    end
  end

  defp unique_qid, do: "Q#{System.unique_integer([:positive])}"
end
