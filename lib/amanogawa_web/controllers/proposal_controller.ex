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

  @doc false
  def new(conn, %{"sel" => qid, "field" => field}) when field in @fields do
    if EventId.valid?(qid) do
      redirect(conn, to: ~p"/?sel=#{qid}&propose_field=#{field}")
    else
      redirect(conn, to: ~p"/")
    end
  end

  def new(conn, %{"new_event" => "1"}) do
    redirect(conn, to: ~p"/?propose_new_event=1")
  end

  def new(conn, _params) do
    redirect(conn, to: ~p"/")
  end
end
