defmodule AmanogawaWeb.Contributions.Attribution do
  @moduledoc """
  Shared public attribution for the transparency pages (issue #038,
  `AmanogawaWeb.ContributionsLive`, `AmanogawaWeb.ContributionLive`): the
  ONE place that turns a list of `author_id`/`actor_id`s into display
  names, in a SINGLE `Amanogawa.Accounts.display_names_by_ids/1` call per
  page load, never one query per row (F08 overview's "jamais de N+1,
  jamais d'email").

  Never resolves anything past a display name: an id absent from the
  result (anonymized or deleted account, issue #038) and a bare `nil` id
  both render as the caller-supplied "compte supprimé" label, so a
  template never needs to special-case either.
  """

  alias Amanogawa.Accounts

  @doc """
  Resolves every distinct, non-`nil` id in `ids` to its public display
  name, one query regardless of how many times an id repeats on the page.
  """
  @spec resolve_names([Ecto.UUID.t() | nil]) :: %{Ecto.UUID.t() => String.t() | nil}
  def resolve_names(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Accounts.display_names_by_ids()
  end

  @doc """
  The display label for `id` from an already-`resolve_names/1`-built map:
  `deleted_label` for a `nil` id, an id with no display name (never seen)
  or an id absent from `names` (anonymized/deleted, issue #038).
  """
  @spec name(%{Ecto.UUID.t() => String.t() | nil}, Ecto.UUID.t() | nil, String.t()) ::
          String.t()
  def name(_names, nil, deleted_label), do: deleted_label
  def name(names, id, deleted_label), do: Map.get(names, id) || deleted_label
end
