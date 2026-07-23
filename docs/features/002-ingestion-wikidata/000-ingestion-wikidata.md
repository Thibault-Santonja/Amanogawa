# F02 -- Ingestion Wikidata / Wikipedia

> Phase 1 | Priorité P0 | Estimation : 2-3 semaines

## Résumé

Construire le pipeline d'ingestion : extraction des événements historiques depuis Wikidata (endpoint QLever), normalisation des dates anciennes (modèle HistoricalDate), résolution des coordonnées en cascade, import des relations typées entre événements, puis enrichissement paresseux des résumés via l'API REST Wikipedia. Pipelines Oban idempotents, rejouables, tracés dans `ingestion.sync_runs`.

Fondé sur l'ADR 0003 et l'étude `docs/studies/2026-07-sources-donnees-historiques.md`. Corpus visé : ~420 000 événements datés et géolocalisables, dont ~17 000 avec article FR et ~29 000 avec article EN.

## Analyse

### Architecture

- Contexte `Amanogawa.Ingestion` : behaviours `SparqlClient` et `WikipediaClient` (ports), adaptateurs Req (QLever, WDQS, REST Wikipedia), workers Oban, tables `ingestion.sync_runs` et `ingestion.source_records`.
- Contexte `Amanogawa.Atlas` : schémas `Event`, `EventLink` (+ `Polity`/`Border` en F05), API publique d'upsert par QID. Ingestion écrit dans Atlas UNIQUEMENT via cette API.
- `HistoricalDate` : embedded schema partagé (année astronomique signée, mois/jour nullables, précision 0-11, calendrier), colonnes plates en base (ADR 0006).
- Extraction paginée par templates SPARQL vétés (pas d'interpolation brute), liste noire de classes parasites maintenue en module.

### Pièges connus (à traiter explicitement)

- Précision lue via `psv:`/`wikibase:timePrecision` (jamais `wdt:` seul).
- Années négatives : le canal RDF/SPARQL est déjà en convention astronomique (490 av. J.-C. = année -489), c'est le canal JSON des dumps qui livre -490 et demande un décalage de +1. Normalisation testée sur un événement BCE connu (bataille de Marathon, Q31900 : valeur interne -489).
- Faux "1er janvier" : si precision <= 9, tronquer mois/jour.
- Provenance des coordonnées tracée : `:direct` (P625), `:place` (P276 -> P625).

### Sécurité / Éthique

- User-Agent identifié sur chaque requête sortante ; concurrence bornée ; backoff sur 429 ; cache persistant des résumés (fetched_at) ; attribution CC BY-SA stockée avec l'extrait.
- Jamais d'appel réseau dans les tests : fixtures enregistrées dans `test/support/fixtures/`.

### Performance

- Upserts par lots (`insert_all` avec `on_conflict`), transactions bornées, index uniques sur `qid`.
- Sync mensuelle planifiée (Oban Cron) ; import initial via mix task pilotable.

## User Stories

- GIVEN une base vide, WHEN je lance `mix amanogawa.sync events`, THEN les événements Wikidata (filtrés, normalisés) sont importés avec date+précision, coordonnées et provenance, et le run est tracé.
- GIVEN des événements importés, WHEN le worker d'enrichissement passe, THEN les résumés FR (repli EN) sont cachés avec attribution et horodatage.
- GIVEN un import déjà effectué, WHEN je relance la sync, THEN le résultat est identique (idempotence) et seules les nouveautés sont écrites.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #006 HistoricalDate (embedded schema + normalisation) | 001-historical-date.md | 12h |
| #007 Contexte Atlas : Event, EventLink, upserts | 002-contexte-atlas-event.md | 12h |
| #008 SparqlClient : behaviour + adaptateur QLever | 003-sparql-client-qlever.md | 8h |
| #009 Templates SPARQL d'extraction + pagination + blocklist | 004-templates-sparql-extraction.md | 12h |
| #010 Worker Oban d'import des événements + sync_runs | 005-worker-import-evenements.md | 12h |
| #011 Import des relations entre événements | 006-import-relations.md | 8h |
| #012 WikipediaClient + enrichissement des résumés | 007-enrichissement-wikipedia.md | 12h |
| #013 Mix task de sync + planification Oban Cron | 008-mix-task-sync.md | 6h |

## Dépendances

- Prérequis : F01 (#001, #002).
- Sortie : F03 (la carte a besoin d'événements), F05 (mêmes patterns d'import).
