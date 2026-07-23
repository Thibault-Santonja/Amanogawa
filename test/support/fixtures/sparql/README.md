# SPARQL fixtures

Recorded `application/sparql-results+json` responses used by
`test/amanogawa/ingestion/sparql_client/qlever_test.exs` (via `Req.Test`) and
by `Amanogawa.SparqlFixtures` for higher-level ingestion tests. No test ever
calls a real SPARQL endpoint; every fixture below was captured once, outside
the test suite, with a disposable `curl` request identified with the project
User-Agent (`Amanogawa/0.1.0 (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`).

## nominal.json

Captured 2026-07-23 from `https://qlever.dev/api/wikidata`. Real events with
direct coordinates (P625), a French label, and a French Wikipedia article
link, following the canonical extraction pattern of
`.claude/skills/wikidata-query/SKILL.md`.

```sparql
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
PREFIX wikibase: <http://wikiba.se/ontology#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX schema: <http://schema.org/>

SELECT ?event ?eventLabel ?date ?datePrecision ?coord ?articleFr WHERE {
  VALUES ?event { wd:Q31900 wd:Q6539 }
  OPTIONAL { ?event rdfs:label ?eventLabel . FILTER(LANG(?eventLabel) = "fr") }
  ?event p:P585/psv:P585 ?dateNode .
  ?dateNode wikibase:timeValue ?date ;
            wikibase:timePrecision ?datePrecision .
  OPTIONAL { ?event wdt:P625 ?coord . }
  OPTIONAL {
    ?articleFr schema:about ?event ;
               schema:isPartOf <https://fr.wikipedia.org/> .
  }
}
ORDER BY ?event
```

Q31900 (battle of Marathon) is the BCE regression case from the wikidata-query
skill: three P585 statements (dates hesitate between three days in September
490 BCE across sources), all serialized `-0489-...` (RDF/SPARQL is already in
astronomical year numbering, unlike the JSON dumps which need a +1 shift).
Q6539 (storming of the Bastille) covers a plain, single-date, positive-year
case with a distinct precision-11 (day) value.

## empty.json

Captured 2026-07-23 from `https://qlever.dev/api/wikidata`, querying a
nonexistent QID (`wd:Q3141592653589`) with the same date-extraction shape as
above. Zero bindings, real `head`/`results` envelope.

```sparql
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
PREFIX wikibase: <http://wikiba.se/ontology#>

SELECT ?event ?eventLabel ?date ?datePrecision ?coord WHERE {
  VALUES ?event { wd:Q3141592653589 }
  ?event p:P585/psv:P585 ?dateNode .
  ?dateNode wikibase:timeValue ?date ;
            wikibase:timePrecision ?datePrecision .
  OPTIONAL { ?event wdt:P625 ?coord . }
}
```

## large.json

Captured 2026-07-23 from `https://qlever.dev/api/wikidata`: 3000 battle
(`wd:Q178561`) events with dates and, where present, direct coordinates.
Used for the "large response decodes without degradation" limit case.

```sparql
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
PREFIX wikibase: <http://wikiba.se/ontology#>

SELECT ?event ?date ?datePrecision ?coord WHERE {
  ?event wdt:P31/wdt:P279* wd:Q178561 .
  ?event p:P585/psv:P585 ?dateNode .
  ?dateNode wikibase:timeValue ?date ;
            wikibase:timePrecision ?datePrecision .
  OPTIONAL { ?event wdt:P625 ?coord . }
}
LIMIT 3000
```

## malformed.json

Not captured: QLever does not spontaneously emit broken JSON for a valid
query, and deliberately breaking the transport to force one would violate
Wikimedia etiquette. Constructed by hand on 2026-07-23 as a truncated
`nominal.json`-shaped document (valid JSON opening, cut off mid-object), to
exercise the adapter's `{:decode_error, _}` path the same way a network
interruption or a proxy truncating a response body would.

## error.html

Not captured for the same reason: real requests to
`https://qlever.dev` returned either a JSON error body (400, on invalid
SPARQL) or an empty body (302/404), never a substantive HTML page. This
fixture reproduces the shape of an out-of-contract response the etiquette
skill and issue #008 call out: an intermediary (reverse proxy, CDN) serving
an HTML error page instead of the expected
`application/sparql-results+json`, as a generic `502 Bad Gateway` (nginx)
page. Constructed by hand on 2026-07-23.

## events_page.json (#009)

Captured 2026-07-23 from `https://qlever.dev/api/wikidata`, by rendering
and running the exact query `Amanogawa.Ingestion.Wikidata.Templates.
events_page/1` produces for the slice `[178000, 179300)`:

```sparql
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>
PREFIX p: <http://www.wikidata.org/prop/>
PREFIX psv: <http://www.wikidata.org/prop/statement/value/>
PREFIX wikibase: <http://wikiba.se/ontology#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
PREFIX schema: <http://schema.org/>
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>

SELECT ?e
       (SAMPLE(?labelFrV) AS ?labelFr) (SAMPLE(?labelEnV) AS ?labelEn)
       (SAMPLE(?descFrV) AS ?descFr) (SAMPLE(?descEnV) AS ?descEn)
       (SAMPLE(?kindV) AS ?kind)
       (SAMPLE(?beginTimeRaw) AS ?beginTime) (SAMPLE(?beginPrecisionRaw) AS ?beginPrecision) (SAMPLE(?beginCalendarRaw) AS ?beginCalendar)
       (SAMPLE(?endTimeV) AS ?endTime) (SAMPLE(?endPrecisionV) AS ?endPrecision) (SAMPLE(?endCalendarV) AS ?endCalendar)
       (SAMPLE(?coordDirectV) AS ?coordDirect) (SAMPLE(?coordPlaceV) AS ?coordPlace)
       (SAMPLE(?articleFrV) AS ?articleFr) (SAMPLE(?articleEnV) AS ?articleEn)
       (SAMPLE(?sitelinkCountV) AS ?sitelinkCount)
WHERE {
  ?e wdt:P31/wdt:P279* wd:Q1190554 .
  BIND(xsd:integer(STRAFTER(STR(?e), "http://www.wikidata.org/entity/Q")) AS ?qidNum)
  FILTER(?qidNum >= 178000 && ?qidNum < 179300)
  MINUS { VALUES ?blocked { <Blocklist.qids/0, see amanogawa/ingestion/wikidata/blocklist.ex> } ?e wdt:P31 ?blocked }
  { ?e p:P585/psv:P585 ?beginNode585 . ?beginNode585 wikibase:timeValue ?beginTimeRaw ; wikibase:timePrecision ?beginPrecisionRaw ; wikibase:timeCalendarModel ?beginCalendarRaw . }
  UNION
  { MINUS { ?e p:P585/psv:P585 ?anyBeginNode585 } ?e p:P580/psv:P580 ?beginNode580 . ?beginNode580 wikibase:timeValue ?beginTimeRaw ; wikibase:timePrecision ?beginPrecisionRaw ; wikibase:timeCalendarModel ?beginCalendarRaw . }
  OPTIONAL { ?e p:P582/psv:P582 ?endNode . ?endNode wikibase:timeValue ?endTimeV ; wikibase:timePrecision ?endPrecisionV ; wikibase:timeCalendarModel ?endCalendarV . }
  OPTIONAL { ?e wdt:P625 ?coordDirectV . }
  OPTIONAL { ?e wdt:P276/wdt:P625 ?coordPlaceV . }
  FILTER(BOUND(?coordDirectV) || BOUND(?coordPlaceV))
  OPTIONAL { ?e rdfs:label ?labelFrV . FILTER(LANG(?labelFrV) = "fr") }
  OPTIONAL { ?e rdfs:label ?labelEnV . FILTER(LANG(?labelEnV) = "en") }
  OPTIONAL { ?e schema:description ?descFrV . FILTER(LANG(?descFrV) = "fr") }
  OPTIONAL { ?e schema:description ?descEnV . FILTER(LANG(?descEnV) = "en") }
  OPTIONAL { ?e wdt:P31 ?kindV . }
  OPTIONAL { ?articleFrV schema:about ?e ; schema:isPartOf <https://fr.wikipedia.org/> . }
  OPTIONAL { ?articleEnV schema:about ?e ; schema:isPartOf <https://en.wikipedia.org/> . }
  OPTIONAL { ?e wikibase:sitelinks ?sitelinkCountV . }
}
GROUP BY ?e
ORDER BY ?e
LIMIT 200
OFFSET 0
```

26 real, diverse bindings: begin precisions 9, 10 and 11; direct-only,
place-only and direct+place coordinate combinations; events with both a
begin and an end date (wars); events with a French article, an English
article, both, or neither (`Q178530`). Used as the nominal page fixture for
`Amanogawa.Ingestion.Wikidata.EventDecoder` and, later, the import worker
(#010).

## marathon.json (#009)

Captured 2026-07-23 from `https://qlever.dev/api/wikidata`, rendering
`Templates.events_by_qids(["Q31900"])` (same query shape as above, `VALUES
?e { wd:Q31900 }` instead of a slice filter). This is the RDF
astronomical-year regression fixture: the battle of Marathon has three
`P585` statements (dates hesitate across sources), all serialized
`-0489-...`, decoding to internal year `-489` (490 BCE, ADR 0006) with no
correction applied to the RDF channel.

Historical note: early project documentation and the first #007 fixtures
referred to the battle of Marathon as `Q46335`, which is in fact
"typewriter" on Wikidata. The real battle of Marathon is `Q31900`; every
reference in code, tests and docs now uses `Q31900`.

## hostile_bindings.json (#009)

Not captured: each row is a data-quality failure `EventDecoder.decode/1`
must reject without crashing, which QLever does not spontaneously produce
for a syntactically valid query. Constructed by hand on 2026-07-23,
`events_page.json`-shaped, one row per failure mode: a date missing
`beginPrecision`, a `coordDirect` WKT literal that is not a `POINT(...)`,
an entity URI that is a statement node rather than a plain QID entity
(`http://www.wikidata.org/entity/statement/Q31900-...`), and a `beginTime`
literal that does not match the RDF time format at all.

## links_page.json (#011)

QLever (`https://qlever.dev/api/wikidata`) returned `502 Bad Gateway` on
every attempt at capture time (2026-07-23), including the exact
`Templates.links_page/1` query for the `[178000, 179300)` slice this
fixture's sibling `events_page.json` uses: the property-path membership
check on both `?source` and `?target` (`wdt:P31/wdt:P279* wd:Q1190554`
twice) is also too expensive for WDQS's 60s budget over that range
(`.claude/skills/wikidata-query/SKILL.md`: this shape needs QLever's
absence of a timeout).

Real relation data was instead captured from WDQS
(`https://query.wikidata.org/sparql`), same User-Agent, anchored on a
`VALUES ?source { ... }` list of real `Q1190554` QIDs already used
elsewhere in this directory (`events_page.json`, `marathon.json`) rather
than the live slice filter, which keeps the property-path cost bounded
enough for WDQS to answer:

```sparql
PREFIX wd: <http://www.wikidata.org/entity/>
PREFIX wdt: <http://www.wikidata.org/prop/direct/>

SELECT ?source ?target ?property WHERE {
  VALUES ?source { wd:Q178510 wd:Q178842 wd:Q178975 wd:Q178809 wd:Q188709 wd:Q208433 wd:Q844930 }
  VALUES (?prop ?property) {
    (wdt:P361 "P361") (wdt:P155 "P155") (wdt:P156 "P156")
    (wdt:P793 "P793") (wdt:P1344 "P1344")
  }
  ?source ?prop ?target .
}
```

(a companion query with `?source` swapped for the known reverse partners
`wd:Q917167`, `wd:Q1524`, `wd:Q13534153` confirmed the real, symmetric
`P155`/`P156` duplicate kept in this fixture: Q178975 `P156` Q917167 and
Q917167 `P155` Q178975 both hold on Wikidata, and normalize to the same
link).

Nine bindings: seven distinct relations covering all five properties
(`P361` x2, `P155` x1 beyond the duplicate below, `P156`/`P155` as one
real symmetric duplicate pair on `Q178975`/`Q917167`, `P793` x1, `P1344`
x1), plus a ninth binding not found in the samples queried: a self-link
(`source == target`). Genuine Wikidata self-links on these properties are
rare data-quality artifacts, not something a handful of targeted queries
is likely to surface; this one row was added by hand, reusing a real QID
already present in the fixture (`Q179250`, the French invasion of
Russia), the same convention as `hostile_bindings.json`.

Used by `Amanogawa.Ingestion.Wikidata.LinkDecoderTest` (decoding,
deduplication, self-link rejection) and
`Amanogawa.Ingestion.Workers.ImportLinksTest` (end-to-end counts against a
partially preloaded local corpus).

## prehistory.json (#009)

Not captured: no real, richly-annotated `Q1190554` occurrence with a
precision this coarse and this deep in the past was found in the ranges
sampled while building `events_page.json` (network to QLever was also
intermittently unavailable, `502`, while searching further). Constructed
by hand on 2026-07-23 as a single realistic binding (Toba supereruption,
`-123000`, precision 5, ten-thousand-year), used for the "deep prehistory
decodes correctly" limit case.
