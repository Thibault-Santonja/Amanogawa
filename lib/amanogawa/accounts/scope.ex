defmodule Amanogawa.Accounts.Scope do
  @moduledoc """
  The value assigned to `@current_scope` in every conn and every
  LiveView socket (issue #032, F07 overview: "`@current_scope.user`,
  jamais `@current_user`"), on the model of Phoenix 1.8's own scope
  convention.

  `user` is `nil` for an anonymous visitor: the web layer always assigns
  a `Scope` struct, never a bare `nil`, so `@current_scope.user` is a
  safe read whether or not the visitor is signed in.

  Deliberately a struct with a single field today: it is the seam F08
  (collaborative editor) will grow into for moderation roles without
  changing any existing `@current_scope.user` call site.
  """

  alias Amanogawa.Accounts.User

  @type t :: %__MODULE__{user: User.t() | nil}

  defstruct user: nil

  @doc """
  Builds a scope for `user` (a `User` struct or `nil` for an anonymous
  visitor).

  ## Examples

      iex> Amanogawa.Accounts.Scope.for_user(nil)
      %Amanogawa.Accounts.Scope{user: nil}

  """
  @spec for_user(User.t() | nil) :: t()
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: %__MODULE__{user: nil}
end
