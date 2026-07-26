defmodule Amanogawa.Contributions.DecisionNotifier do
  @moduledoc """
  Port for delivering a sober, decision-only email to a contribution's
  author (issue #037, F08 overview / ADR 0008 anti-dark-patterns:
  "un email sobre à la décision et à l'issue d'appel, rien d'autre").
  `Amanogawa.Contributions.accept_override/3`, `reject_override/3` and
  `review_appeal/3` depend on this behaviour only, never on
  `Amanogawa.Mailer` or Swoosh directly, so they stay testable with Mox
  (`Amanogawa.Contributions.DecisionNotifierMock`,
  `test/support/mocks.ex`), exactly like `Amanogawa.Accounts.
  MagicLinkNotifier`.

  No transport concern crosses this boundary: the domain calls
  `deliver/5` with plain strings and gets back `:ok` or a tagged error.
  `contribution_path` is a relative path (`"/contributions/<id>"`), never
  an absolute URL: turning it into one requires the endpoint's host
  configuration, a web-layer concern this context never depends on
  (mirrors `Amanogawa.Accounts.deliver_magic_link/4`'s injected
  `magic_link_url_fun`, applied here as the adapter's own responsibility
  instead of a function argument, since every call site wants the exact
  same path shape).
  """

  @type outcome :: :accepted | :rejected | :appeal_accepted | :appeal_rejected

  @doc """
  Delivers the decision email for `outcome` (the reviewer's motive,
  `message`, always included) to `email`, rendered in `locale` (`"fr"` or
  `"en"`). `contribution_path` is the relative path to the contribution's
  public page (`"/contributions/<id>"`, issue #038's route, posed in
  #037): the adapter is responsible for turning it into an absolute,
  clickable URL.

  Returns `:ok` on success, `{:error, reason}` otherwise; the caller
  never lets a delivery failure crash or roll back an already-committed
  decision (mirrors `Amanogawa.Accounts.deliver_magic_link/4`'s own
  contract).
  """
  @callback deliver(
              email :: String.t(),
              outcome :: outcome(),
              message :: String.t(),
              contribution_path :: String.t(),
              locale :: String.t()
            ) :: :ok | {:error, term()}
end
