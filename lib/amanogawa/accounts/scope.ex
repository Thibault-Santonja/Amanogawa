defmodule Amanogawa.Accounts.Scope do
  @moduledoc """
  The value assigned to `@current_scope` in every conn and every
  LiveView socket (issue #032, F07 overview: "`@current_scope.user`,
  jamais `@current_user`"), on the model of Phoenix 1.8's own scope
  convention.

  `user` is `nil` for an anonymous visitor: the web layer always assigns
  a `Scope` struct, never a bare `nil`, so `@current_scope.user` is a
  safe read whether or not the visitor is signed in.

  Grew a `reviewer?` field in issue #034 (F08 overview's moderation role):
  the seam this struct was deliberately left for in F07 is what
  `AmanogawaWeb.UserAuth.require_reviewer/2` and
  `on_mount(:require_reviewer)` (#035) gate on, without ever reaching past
  this facade into `Amanogawa.Accounts.User`'s own `role` field.
  """

  alias Amanogawa.Accounts.User

  @type t :: %__MODULE__{user: User.t() | nil, reviewer?: boolean()}

  defstruct user: nil, reviewer?: false

  @doc """
  Builds a scope for `user` (a `User` struct or `nil` for an anonymous
  visitor). `reviewer?` mirrors the user's `role` (always `false` for an
  anonymous visitor).

  ## Examples

      iex> Amanogawa.Accounts.Scope.for_user(nil)
      %Amanogawa.Accounts.Scope{user: nil, reviewer?: false}

  """
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{role: role} = user),
    do: %__MODULE__{user: user, reviewer?: role == :reviewer}

  def for_user(nil), do: %__MODULE__{user: nil, reviewer?: false}
end
