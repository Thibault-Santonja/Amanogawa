defmodule AmanogawaWeb.Params.EventId do
  @moduledoc """
  Validates a Wikidata QID received as a path parameter (`GET
  /api/events/:qid/summary`, `GET /api/events/:qid/links`, issues #016 and
  #017), before any database access (`.claude/rules/security.md`).

  The pattern mirrors `Amanogawa.Atlas.Event`'s own QID format (`Q`
  followed by digits), with an explicit upper bound on length:
  `Amanogawa.Atlas.Event` validates already-ingested, trusted data, while
  this module is the first line of defense against a hostile path
  parameter (an absurdly long digit string, a `../../etc/passwd`
  traversal attempt, a `Q1' OR 1=1` injection attempt), so it is
  deliberately bounded rather than open-ended.

  `AmanogawaWeb.Params.ExploreParams.valid_qid?/1` delegates here too, so
  every QID accepted anywhere in the web layer, client-pushed selection or
  API path parameter, shares this single bounded definition.
  """

  # No Wikidata entity QID has ever needed more than a handful of digits
  # (as of 2026, the largest are in the low hundreds of millions, 9
  # digits): 15 digits is a generous ceiling that accepts every legitimate
  # QID for the foreseeable future while rejecting abuse.
  @qid_regex ~r/\AQ\d{1,15}\z/

  @doc """
  True when `value` is a binary matching the bounded QID format.

  ## Examples

      iex> AmanogawaWeb.Params.EventId.valid?("Q31900")
      true

      iex> AmanogawaWeb.Params.EventId.valid?("Q1' OR 1=1")
      false

      iex> AmanogawaWeb.Params.EventId.valid?("../../etc/passwd")
      false

      iex> AmanogawaWeb.Params.EventId.valid?("Q" <> String.duplicate("1", 10_000))
      false

  """
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_binary(value), do: Regex.match?(@qid_regex, value)
  def valid?(_other), do: false
end
