# Issue #012 -- Enrichissement des résumés via l'API REST Wikipedia

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #010

---

## Contexte

Wikidata fournit la structure (dates, coordonnées, liens) mais pas les résumés : ils viennent de l'API REST Wikipedia (`https://{lang}.wikipedia.org/api/rest_v1/page/summary/{titre}`), qui retourne titre, description, extrait, miniature et URLs canoniques. L'ADR 0003 impose un enrichissement paresseux, en batch lent : les limites Wikimedia pour le trafic automatisé se sont durcies en 2026, et nous dépendons d'un commun (`.claude/rules/ethics.md`).

Architecture identique à #008 : un behaviour `Amanogawa.Ingestion.WikipediaClient` (port), un adaptateur Req (REST), un mock Mox pour tous les tests. Un worker Oban parcourt les événements possédant un article (fr prioritaire, repli en) et dont l'extrait est absent ou plus vieux que 30 jours, puis stocke extrait, miniature et attribution via la façade Atlas.

Contraintes non négociables :

- User-Agent identifié sur chaque requête ; concurrence bornée (une requête à la fois) ; backoff sur 429 ; jamais d'appel réseau en test.
- Cache persistant : ne jamais re-fetcher un résumé dont `extract_fetched_at` a moins de 30 jours (configurable). Les résumés sont rafraîchis au plus mensuellement.
- Attribution : les extraits Wikipedia sont CC BY-SA 4.0 ; l'attribution (URL de l'article source, licence) est stockée avec l'extrait pour être affichée par la couche web.

Le volume cible est modeste au regard du corpus : ~17 000 articles fr et ~29 000 en sur le sous-ensemble riche (étude §1), l'enrichissement complet s'étale donc sur des heures, pas des semaines.

## User Story

> En tant qu'utilisateur, je veux lire un résumé sourcé et attribué (avec image quand elle existe) au survol d'un événement, afin de comprendre de quoi il s'agit sans quitter la carte.

---

## Tâches

- [ ] Behaviour `Amanogawa.Ingestion.WikipediaClient` :
  - `@callback fetch_summary(lang :: :fr | :en, title :: String.t()) :: {:ok, Summary.t()} | {:error, error()}` ;
  - erreurs taguées : `:not_found`, `{:rate_limited, retry_after | nil}`, `:timeout`, `{:http_error, status}`, `{:transport_error, reason}`, `{:decode_error, reason}` ;
  - structure `Amanogawa.Ingestion.WikipediaClient.Summary` : `title`, `description`, `extract`, `thumbnail_url` (nul si absent), `article_url` (URL canonique desktop), `lang`.
- [ ] Adaptateur `Amanogawa.Ingestion.WikipediaClient.Rest` (Req) : GET `api/rest_v1/page/summary/{titre}` sur le domaine de la langue, titre extrait de l'URL d'article stockée (dernier segment, décodé puis ré-encodé pour l'URL), suivi des redirections, User-Agent `Amanogawa/<version> (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`, timeouts explicites, mapping des erreurs (404 -> `:not_found`, 429 -> `{:rate_limited, _}` après backoff borné).
- [ ] Migration additive sur `atlas.events` : `extract_fetched_at` (utc_datetime), `thumbnail_url` (string), `extract_attribution` (jsonb : `article_url`, `license`, `lang`). Mettre à jour la liste `@wikidata_columns` de #007 pour que les upserts Wikidata n'écrasent jamais ces colonnes ni les extraits.
- [ ] Façade `Amanogawa.Atlas` (extension) :
  - `list_events_to_enrich/1` (opts : `limit`, `max_age_days`) : événements avec `wiki_url_fr` ou `wiki_url_en` et extrait absent ou `extract_fetched_at` plus vieux que `max_age_days`, ordonnés par `sitelink_count` décroissant (les événements importants d'abord) ;
  - `put_event_summary/2` : écrit `extract_fr` ou `extract_en` selon la langue, `thumbnail_url`, `extract_attribution`, `extract_fetched_at` ;
  - `mark_summary_attempt/1` : horodate `extract_fetched_at` sans extrait (cas `:not_found`) pour ne pas retenter avant l'expiration du cache.
- [ ] Worker `Amanogawa.Ingestion.Workers.EnrichSummaries` (queue `:wikipedia`, concurrence 1) :
  - un job traite un petit lot (50 événements) : pour chacun, fr si `wiki_url_fr` existe, sinon en ; stocke le résultat via la façade Atlas ;
  - à la fin du lot, planifie le job du lot suivant avec un délai (`schedule_in`) pour lisser la charge (batch lent) ; s'arrête quand `list_events_to_enrich/1` est vide et clôt le run ;
  - sur `{:rate_limited, retry_after}` : snooze du job (`{:snooze, s}`) plutôt qu'échec ;
  - `SyncRun` de kind `summaries` : compteurs `fetched`, `enriched_fr`, `enriched_en`, `not_found`, `errors`, curseur implicite (la sélection exclut d'elle-même les événements déjà traités, le run est reprennable par construction).
- [ ] Façade `Amanogawa.Ingestion` : `start_summaries_enrichment/1` (opts : `limit`, `dry_run`, `max_age_days`), refus de runs `summaries` concurrents.
- [ ] Configuration : queue Oban `:wikipedia` (limit: 1), `config :amanogawa, :wikipedia_client, ...` (adaptateur réel en prod, `WikipediaClientMock` en test), `summary_max_age_days` (défaut 30), délai inter-lots.
- [ ] Fixtures réelles dans `test/support/fixtures/wikipedia/` : résumé fr nominal (avec thumbnail), résumé en (sans thumbnail), réponse 404, réponse 429, JSON inattendu ; `README.md` de provenance.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : l'adaptateur décode la fixture fr en `%Summary{}` complet (extract, thumbnail_url, article_url) ; extraction du titre depuis une `wiki_url` avec caractères encodés (apostrophes, accents).
- [ ] **Edge case** : résumé sans thumbnail -> `thumbnail_url` nil ; titre avec parenthèses et diacritiques ; événement avec article en uniquement -> repli en.
- [ ] **Error case** : 404 -> `{:error, :not_found}` ; JSON malformé -> `{:error, {:decode_error, _}}` ; timeout -> `{:error, :timeout}`.
- [ ] **Limit case** : 429 avec `Retry-After` -> backoff borné puis `{:error, {:rate_limited, n}}` si persistant ; extrait très long stocké intégralement.

### Property-based tests (si applicable)

- [ ] **Property** : l'extraction de titre depuis une URL d'article générée (segments encodés variés) ne lève jamais et produit un titre re-encodable en URL valide.

### Doctests (si applicable)

- [ ] **Doctest** : fonction pure d'extraction du titre depuis une `wiki_url` (exemples fr et en dans le moduledoc).

### Tests d'intégration

- [ ] **Intégration (DataCase + Oban.Testing, Mox)** : base avec événements fr, en-seulement, sans article, et déjà enrichi récent -> le worker enrichit les bons événements dans l'ordre d'importance, applique le repli en, ignore l'événement sans article et l'événement à cache frais ; attribution et `extract_fetched_at` renseignés ; `SyncRun` `completed` avec compteurs exacts.
- [ ] **Intégration (cache)** : relancer l'enrichissement immédiatement -> zéro appel au mock (tous les `extract_fetched_at` sont frais) ; avec `extract_fetched_at` vieilli artificiellement au-delà de 30 jours -> re-fetch.
- [ ] **Intégration (not_found)** : article 404 -> `mark_summary_attempt/1` horodate sans extrait et l'événement n'est pas représenté avant expiration du cache.
- [ ] **Intégration (rate limit)** : mock retournant `{:rate_limited, 60}` -> le job snooze (assertion Oban.Testing, pas de sleep) et le run reste `running`.
- [ ] **Intégration (upsert)** : un upsert Wikidata (#007) rejoué après enrichissement ne touche ni extraits, ni thumbnail, ni attribution.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion/wikipedia_client.ex` (behaviour + struct `Summary`)
  - `lib/amanogawa/ingestion/wikipedia_client/rest.ex`
  - `lib/amanogawa/ingestion/workers/enrich_summaries.ex`
  - `lib/amanogawa/ingestion.ex` (façade)
  - `lib/amanogawa/atlas.ex` (`list_events_to_enrich/1`, `put_event_summary/2`, `mark_summary_attempt/1`, mise à jour `@wikidata_columns`)
  - `priv/repo/migrations/NNN_add_summary_columns_to_atlas_events.exs`
  - `config/config.exs`, `config/test.exs`
  - `test/support/mocks.ex` (ajout `WikipediaClientMock`)
  - `test/support/fixtures/wikipedia/` (fixtures + `README.md`)
  - `test/amanogawa/ingestion/wikipedia_client/rest_test.exs`
  - `test/amanogawa/ingestion/workers/enrich_summaries_test.exs`
- **Documentation de référence** : ADR 0003, `.claude/rules/ethics.md` (étiquette, attribution CC BY-SA), `.claude/memory/data-sources.md` §Wikipedia, étude §2, [Rate limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits), [API:Etiquette](https://www.mediawiki.org/wiki/API:Etiquette).
- **Compétences requises** : Req, Mox, Oban (snooze, schedule_in), encodage d'URL, licences Creative Commons.
- **Points d'attention** :
  - L'attribution stockée doit suffire à la couche web pour afficher "Source : Wikipédia, CC BY-SA 4.0" avec lien vers l'article : ne pas se contenter de la licence sans l'URL.
  - Horodater aussi les 404 : sans cela le worker retenterait les mêmes articles manquants à chaque run.
  - Le repli en n'écrase jamais un extrait fr existant ; un événement peut légitimement finir avec les deux extraits au fil des runs.
  - Pas de `Process.sleep` dans le worker : le lissage passe par `schedule_in` et la concurrence de queue.
  - Jamais d'appel Wikipedia côté client web : tout extrait affiché vient du cache en base (règle projet).
  - La priorité par `sitelink_count` garantit que les événements les plus visibles sont enrichis en premier si le run est interrompu.
