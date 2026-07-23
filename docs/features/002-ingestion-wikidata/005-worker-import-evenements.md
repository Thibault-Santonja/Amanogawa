# Issue #010 -- Worker Oban d'import des événements et table sync_runs

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #007, #009

---

## Contexte

Cette issue assemble le pipeline d'import des événements : un worker Oban orchestre le parcours paginé du corpus (templates et tranches de QID de #009), décode et normalise chaque page, puis écrit par lots via l'API publique `Amanogawa.Atlas.upsert_events/1` (#007). Conformément aux règles OTP du projet, tout travail de fond passe par Oban, jamais par un GenServer artisanal.

Chaque exécution est tracée dans une table `ingestion.sync_runs` (schéma PG `ingestion`, créé en #001) : horodatages, compteurs, statut, curseur de progression. Ce traçage donne l'observabilité (que s'est-il passé lors de la dernière sync), la reprise sur erreur (reprendre au curseur du run échoué plutôt que tout rejouer) et alimente la documentation d'exploitation (#013).

Propriétés exigées :

- **Idempotence** : rejouer un import complet sur une base déjà importée aboutit au même état (garanti par l'upsert par QID de #007, prouvé par un test de double run).
- **Reprise** : un run interrompu (crash, erreur réseau persistante) est repris depuis son curseur `{tranche, offset}` sans perdre ni dupliquer de données.
- **Étiquette** : une seule requête SPARQL à la fois (queue à concurrence 1), le backoff transitoire étant géré par l'adaptateur (#008) et la reprise durable par le job.

La façade `Amanogawa.Ingestion` naît ici : c'est le seul point d'entrée public du contexte (utilisé ensuite par la mix task et le cron, #013).

## User Story

> En tant qu'opérateur du projet, je veux lancer un import complet des événements Wikidata, tracé et reprennable, afin de constituer et de resynchroniser le corpus sans surveillance constante et sans risque de doublons.

---

## Tâches

- [ ] Migration : créer la table `ingestion.sync_runs` : `id` UUID v7, `kind` (string : `events`, `links`, `summaries`), `status` (string : `running`, `completed`, `failed`), `started_at`, `finished_at` (utc_datetime, `finished_at` nul tant que le run est actif), `counts` (jsonb, défaut `{}`), `cursor` (jsonb, nul), `last_error` (text, nul), timestamps ; index sur `(kind, started_at)`.
- [ ] Schéma `Amanogawa.Ingestion.SyncRun` (`@schema_prefix "ingestion"`, `kind` et `status` en `Ecto.Enum`) avec changesets de création, de progression (mise à jour `counts` et `cursor`) et de clôture (`completed`/`failed` + `finished_at`).
- [ ] Worker `Amanogawa.Ingestion.Workers.ImportEvents` (queue `:ingestion`, concurrence 1, `max_attempts` bornant les reprises automatiques) :
  - args : `sync_run_id`, tranche courante et offset, plus options (`limit` global, `dry_run`) transmises par la façade ;
  - traite une page : requête via le `SparqlClient` configuré, décodage `EventDecoder`, upsert `Amanogawa.Atlas.upsert_events/1` (sauf `dry_run`), mise à jour des compteurs et du curseur du `SyncRun` ;
  - enchaîne : si la page est pleine, insère le job de la page suivante ; sinon passe à la tranche suivante ; quand toutes les tranches sont épuisées, clôt le run en `completed` ;
  - en cas d'erreur du client SPARQL : laisse Oban rejouer le job (le curseur en base garantit la reprise au bon endroit) ; si `max_attempts` est atteint, clôt le run en `failed` avec `last_error`.
- [ ] Compteurs du run dans `counts` : `pages`, `events_fetched`, `events_upserted`, `events_rejected` (bindings écartés par le décodeur), cumulés de façon atomique à chaque page.
- [ ] Façade `Amanogawa.Ingestion` :
  - `start_events_import/1` (opts : `limit`, `dry_run`) : crée le `SyncRun` en `running` et insère le premier job ; refuse de démarrer si un run `events` est déjà `running` ;
  - `resume_events_import/1` : repart du curseur d'un run `failed` ;
  - `get_sync_run/1`, `last_sync_run/1` (par kind) pour l'observabilité et les tests.
- [ ] Configuration Oban : queue `:ingestion` (limit: 1) ajoutée à la config ; `use Oban.Testing` dans les tests du contexte.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : changesets `SyncRun` (création, progression, clôture) ; transitions de statut valides.
- [ ] **Edge case** : clôture d'un run sans aucune page (corpus vide) -> `completed` avec compteurs à zéro ; `dry_run` ne déclenche aucun appel à `Amanogawa.Atlas` (vérifié par l'état de la base).
- [ ] **Error case** : transition de statut invalide rejetée (`completed` -> `running`) ; `start_events_import/1` refuse un second run simultané.
- [ ] **Limit case** : `limit` inférieur à la taille d'une page tronque correctement l'import et clôt le run.

### Property-based tests (si applicable)

- [ ] **Property** : non applicable en propre (les invariants de normalisation sont couverts par #006 et #009) ; réutiliser les générateurs existants si un besoin apparaît.

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (orchestration avec base de données).

### Tests d'intégration

- [ ] **Intégration (DataCase + Oban.Testing, Mox)** : import complet sur deux tranches et trois pages de fixtures -> tous les événements attendus en base, `SyncRun` `completed`, compteurs exacts, curseur final cohérent. Aucun réseau : `SparqlClientMock` sert les fixtures de #009.
- [ ] **Intégration (idempotence)** : exécuter l'import complet deux fois avec les mêmes fixtures -> même nombre de lignes et mêmes valeurs de colonnes métier après le second run (comparaison de l'état, pas seulement des comptes) ; le second run trace bien son propre `SyncRun`.
- [ ] **Intégration (reprise sur erreur)** : le mock échoue durablement à la page 2 -> run `failed`, curseur sur la page 2 ; `resume_events_import/1` avec un mock redevenu sain termine l'import sans retraiter la page 1 (vérifiable par le nombre d'appels au mock) et l'état final est identique à un import sans incident.
- [ ] **Intégration (enchainement)** : chaque page pleine insère exactement un job suivant (assertions `Oban.Testing` sur les jobs insérés, pas de `Process.sleep`).

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable (le parcours opérateur complet est couvert en #013 via la mix task).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion.ex` (façade publique du contexte)
  - `lib/amanogawa/ingestion/sync_run.ex`
  - `lib/amanogawa/ingestion/workers/import_events.ex`
  - `priv/repo/migrations/NNN_create_ingestion_sync_runs.exs`
  - `config/config.exs` (queue Oban `:ingestion`)
  - `test/amanogawa/ingestion_test.exs`
  - `test/amanogawa/ingestion/sync_run_test.exs`
  - `test/amanogawa/ingestion/workers/import_events_test.exs`
- **Documentation de référence** : ADR 0003 (pipeline idempotent par QID), `.claude/rules/architecture.md` (Oban, façades), `.claude/rules/testing.md` (Oban.Testing, pas de sleep), F02 vue d'ensemble (user story d'idempotence), documentation Oban (unique jobs, testing).
- **Compétences requises** : Oban (workers, insertion de jobs, testing helpers), Ecto multi-schémas, Mox, conception de curseurs de reprise.
- **Points d'attention** :
  - L'écriture dans Atlas passe exclusivement par `Amanogawa.Atlas` : aucun accès à `Amanogawa.Atlas.Event` ni au Repo pour les tables `atlas.*` depuis le contexte Ingestion.
  - Le curseur vit en base (dans le `SyncRun`), pas dans les args du job : c'est lui la source de vérité de la reprise, les args ne portent que la référence au run.
  - Un job = une page : garder les transactions courtes ; jamais un run entier dans un seul job (des heures de travail, inrejouable).
  - Empêcher les runs concurrents du même kind (contrainte applicative dans la façade et unicité Oban sur le job).
  - `dry_run` traverse toute la chaîne (requête, décodage, comptage) et n'omet que l'écriture : c'est l'outil de vérification de #013.
  - Volumétrie cible ~420 000 événements : dimensionner tailles de page et de lots avec #009 (quelques milliers de bindings par page, lots de 500 pour l'upsert).
