defmodule Amanogawa.Ingestion.Wikidata.Blocklist do
  @moduledoc """
  QID classes excluded from event extraction: the `Q1190554` (occurrence)
  tree is noisy with entities that are not, in the historical sense, events
  worth putting on a map and timeline (sports seasons, Olympic delegations,
  award-ceremony editions...).

  `Amanogawa.Ingestion.Wikidata.Templates.events_page/1` excludes every QID
  returned by `qids/0` with `MINUS { VALUES ?blocked { ... } ?e wdt:P31
  ?blocked }`: the check is on the direct `wdt:P31` class only, not its
  `wdt:P279*` superclass closure (cost), so a blocked class only removes
  entities directly typed with it.

  ## Calibration

  This list is a point of continuous curation, not a one-time decision.
  It was seeded by measuring the 20 most frequent `wdt:P31` classes among
  dated `Q1190554` occurrences in a sample of the QID space (`[Q100000,
  Q300000)`, QLever, 2026-07-23):

  | Count | QID | Label | Decision |
  |-------|-----|-------|----------|
  | 1931 | Q26213387 | Olympic delegation | exclude |
  | 934 | Q114609228 | recurring sporting event edition | exclude |
  | 789 | Q27020041 | sports season | exclude |
  | 245 | Q47345468 | tennis tournament edition | exclude |
  | 218 | Q178561 | battle | keep |
  | 174 | Q47018478 | calendar month of a given year | exclude |
  | 173 | Q26132862 | Olympic sports discipline event | exclude |
  | 120 | Q18536594 | Olympic sporting event | exclude |
  | 98 | Q756721 | Atlantic hurricane season | exclude |
  | 91 | Q46190676 | tennis event | exclude |
  | 80 | Q2990963 | figure skating competition | exclude |
  | 73 | Q625298 | peace treaty | keep |
  | 70 | Q131569 | treaty | keep |
  | 60 | Q8036 | Italian Grand Prix | exclude |
  | 52 | Q7997 | French Grand Prix | exclude |
  | 43 | Q124734 | rebellion | keep |
  | 43 | Q110288240 | Eurovision Song Contest edition | exclude |
  | 43 | Q3199915 | massacre | keep |
  | 42 | Q7944 | earthquake | keep |
  | 41 | Q1478437 | association football competition | exclude |

  "Keep" entries are not listed below (nothing to exclude); "exclude"
  entries seeded the list. `Q27968055` (recurring event edition, a sibling
  of `Q114609228`) was found in the same pass and added for the same
  reason. Widening calibration (larger sample, full corpus once the pipeline
  runs end to end) is expected to grow this list over time; each addition
  should be measured the same way, not guessed.
  """

  @qids [
    # Sports seasons, tournament/competition editions, and individual
    # recurring fixtures: numerous, rarely "historical" in the sense this
    # project targets, and already well represented by the sport's own
    # Wikipedia coverage rather than a map/timeline entry.
    {"Q27020041", "sports season"},
    {"Q114609228", "recurring sporting event edition"},
    {"Q27968055", "recurring event edition"},
    {"Q47345468", "tennis tournament edition"},
    {"Q46190676", "tennis event"},
    {"Q26132862", "Olympic sports discipline event"},
    {"Q18536594", "Olympic sporting event"},
    {"Q2990963", "figure skating competition"},
    {"Q8036", "Italian Grand Prix (motor race edition)"},
    {"Q7997", "French Grand Prix (motor race edition)"},
    {"Q1478437", "association football competition"},

    # National Olympic Committee participation records: administrative
    # roll-ups, not events.
    {"Q26213387", "Olympic delegation"},

    # A calendar period, not an occurrence.
    {"Q47018478", "calendar month of a given year"},

    # A recurring aggregate (a whole storm season), as opposed to an
    # individual storm, which stays in scope.
    {"Q756721", "Atlantic hurricane season"},

    # Awards ceremony editions and voting events: administrative/cultural
    # recurring fixtures, not historical occurrences.
    {"Q110288240", "Eurovision Song Contest edition"},

    # Elections: seeded in the F02 overview and the wikidata-query skill as
    # a known noise source; not encountered in the top-20 calibration pass
    # above (the sample happened not to surface one in its top ranks) but
    # kept as a documented, deliberate exclusion.
    {"Q40231", "election"}
  ]

  @doc """
  QIDs of classes excluded from event extraction (see moduledoc for
  calibration data and rationale).

      iex> qids = Amanogawa.Ingestion.Wikidata.Blocklist.qids()
      iex> qids != []
      true
      iex> Enum.all?(qids, &Regex.match?(~r/^Q\\d+$/, &1))
      true

  """
  @spec qids() :: [String.t()]
  def qids, do: Enum.map(@qids, fn {qid, _label} -> qid end)
end
