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
