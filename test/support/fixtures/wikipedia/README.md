# Wikipedia summary fixtures

Recorded `page/summary` REST API responses used by
`test/amanogawa/ingestion/wikipedia_client/rest_test.exs` (via `Req.Test`)
and by `test/amanogawa/ingestion/workers/enrich_summaries_test.exs`. No test
ever calls the real Wikipedia endpoint; every captured fixture below was
fetched once, outside the test suite, with a disposable `curl` request
identified with the project User-Agent
(`Amanogawa/0.1.0 (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`).

## summary_fr.json

Captured 2026-07-23 from
`https://fr.wikipedia.org/api/rest_v1/page/summary/Bataille_de_Marathon`.
Real nominal fr response: `title`, `description`, `extract`, `thumbnail`
(with `source`), `content_urls.desktop.page`. Used as the happy-path fixture
(fr with thumbnail).

## summary_en_no_thumbnail.json

Captured 2026-07-23 from
`https://en.wikipedia.org/api/rest_v1/page/summary/Third_Council_of_the_Lateran`.
Real en response for an article without an infobox image: no `thumbnail`
key at all. Used for the "no thumbnail -> `thumbnail_url` nil" edge case and
for the en-fallback scenario.

## not_found.json

Captured 2026-07-23 from
`https://fr.wikipedia.org/api/rest_v1/page/summary/Article_Inexistant_Test_Amanogawa_Xyz123`
(HTTP 404). Real response body for a nonexistent title:
`{"status":404,"type":"Internal error"}`. The adapter maps the HTTP status
alone to `{:error, :not_found}`; this fixture documents the real body shape,
not something the decoder needs to parse.

## rate_limited.json

Not captured: deliberately forcing a 429 against the real Wikipedia REST API
would mean sending enough traffic to trip the rate limiter, violating
Wikimedia etiquette (`.claude/rules/ethics.md`) for the sake of a test
fixture. Constructed by hand on 2026-07-23, a plausible MediaWiki
rate-limit error body (HTTP 429 is set on the stubbed response, not encoded
in this JSON); used with a `retry-after` response header to exercise the
adapter's backoff and `{:error, {:rate_limited, _}}` path the same way
`test/amanogawa/ingestion/sparql_client/qlever_test.exs` does for QLever.

## malformed.json

Not captured for the same reason as `sparql/malformed.json`: the real
endpoint does not spontaneously emit broken JSON for a valid request.
Constructed by hand on 2026-07-23 as a truncated `summary_en_no_thumbnail.json`-shaped
document (valid JSON opening, cut off mid-string), to exercise the
adapter's `{:decode_error, _}` path the same way a network interruption or a
proxy truncating a response body would.
