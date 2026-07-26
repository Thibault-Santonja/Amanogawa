defmodule AmanogawaWeb.Params.EventId do
  @moduledoc """
  Validates an event identifier received as a path parameter (`GET
  /api/events/:qid/summary`, `GET /api/events/:qid/links`, issues #016 and
  #017), before any database access (`.claude/rules/security.md`).

  Accepts a Wikidata QID (`Q` followed by digits) or, since issue #034, a
  community-contributed event's local identifier (`L` followed by 32
  lowercase hex characters, `Amanogawa.Atlas.Event`'s extended `qid`
  format), each with an explicit upper bound: `Amanogawa.Atlas.Event`
  validates already-ingested, trusted data, while this module is the
  first line of defense against a hostile path parameter (an absurdly
  long digit string, a `../../etc/passwd` traversal attempt, a `Q1' OR
  1=1` injection attempt), so it is deliberately bounded rather than
  open-ended.

  `AmanogawaWeb.Params.ExploreParams.valid_qid?/1` delegates here too, so
  every event id accepted anywhere in the web layer, client-pushed
  selection or API path parameter, shares this single bounded definition.
  """

  # No Wikidata entity QID has ever needed more than a handful of digits
  # (as of 2026, the largest are in the low hundreds of millions, 9
  # digits): 15 digits is a generous ceiling that accepts every legitimate
  # QID for the foreseeable future while rejecting abuse. The `L` variant
  # is exactly 32 lowercase hex characters (a UUID with its dashes
  # stripped, `Amanogawa.Atlas.create_contributed_event/1`), never more
  # or fewer.
  @qid_regex ~r/\A(Q\d{1,15}|L[0-9a-f]{32})\z/

  @doc """
  True when `value` is a binary matching the bounded event id format
  (Wikidata QID or local contribution id).

  ## Examples

      iex> AmanogawaWeb.Params.EventId.valid?("Q31900")
      true

      iex> AmanogawaWeb.Params.EventId.valid?("L" <> String.duplicate("a", 32))
      true

      iex> AmanogawaWeb.Params.EventId.valid?("L" <> String.duplicate("a", 31))
      false

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
