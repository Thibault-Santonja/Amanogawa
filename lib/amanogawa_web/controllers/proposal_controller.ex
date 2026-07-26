defmodule AmanogawaWeb.ProposalController do
  @moduledoc """
  `GET /proposer` (issue #036): the anonymous-visitor entry point for
  "Proposer une correction" / "Proposer un événement"
  (`AmanogawaWeb.Components.EventPanel`, `AmanogawaWeb.ExploreLive`).

  A plain controller action stacked on the `:authenticated` pipeline
  (`AmanogawaWeb.Router`, same scope as `GET /compte/export`): an
  anonymous request never reaches `new/2` at all,
  `AmanogawaWeb.UserAuth.require_authenticated_user/2` stashes THIS exact
  path (query string included) as `"user_return_to"` and redirects to
  `/connexion` first (F07's own mechanic, reused rather than
  reinvented). Once signed in, `AmanogawaWeb.UserAuth.log_in_user/2`
  redirects back here, now authenticated, and `new/2` forwards to
  `AmanogawaWeb.ExploreLive` with the correction/creation query params
  it understands (`propose_field`, `propose_new_event`) so the form opens
  exactly where the visitor left off.

  An already-authenticated visitor also passes through here (the panel's
  link is the same for everyone, F08 overview's "droit affiché, pas un
  privilège caché"): one extra redirect, deliberately kept simple rather
  than duplicating this destination logic in the LiveView.
  """

  use AmanogawaWeb, :controller

  alias AmanogawaWeb.Params.EventId

  @fields ~w(label_fr label_en begin_date end_date position link)

  # Window/camera params forwarded verbatim to `AmanogawaWeb.ExploreLive`
  # (quality review m-finding: the anonymous sign-in round trip must come
  # back to the same view, not the default one). Safe to pass through
  # raw: `AmanogawaWeb.Params.ExploreParams.parse/1` re-validates every
  # one of them and falls back to its default on anything hostile.
  @view_params ~w(from to z lat lng)

  @doc false
  def new(conn, %{"sel" => qid, "field" => field} = params) when field in @fields do
    if EventId.valid?(qid) do
      query =
        params
        |> view_query()
        |> Map.merge(%{"sel" => qid, "propose_field" => field})

      redirect(conn, to: "/?" <> URI.encode_query(query))
    else
      redirect(conn, to: ~p"/")
    end
  end

  def new(conn, %{"new_event" => "1"} = params) do
    query = params |> view_query() |> Map.put("propose_new_event", "1")

    redirect(conn, to: "/?" <> URI.encode_query(query))
  end

  def new(conn, _params) do
    redirect(conn, to: ~p"/")
  end

  defp view_query(params) do
    params
    |> Map.take(@view_params)
    |> Map.filter(fn {_key, value} -> is_binary(value) end)
  end
end
