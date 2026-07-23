# Issue #007 -- Contexte Atlas : schémas Event et EventLink, upserts par lots

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #006

---

## Contexte

Le contexte Atlas est le read model servi à l'interface : il stocke les événements historiques et leurs liens typés dans le schéma PostgreSQL `atlas`. Cette issue crée les deux premiers schémas Ecto du contexte (`Event`, `EventLink`), leurs migrations avec index, et l'API publique d'écriture par lots que le pipeline d'ingestion (F02) utilisera. La règle d'architecture est stricte : Ingestion écrit dans Atlas uniquement via la façade `Amanogawa.Atlas`, jamais par accès direct aux modules internes ou au Repo.

Le modèle est fixé par `.claude/memory/domain-model.md` et l'ADR 0006 :

- Un événement est identifié métier par son QID Wikidata (`Q31900`), clé unique d'upsert ; l'identifiant interne est un UUID v7.
- Les dates begin/end sont des `HistoricalDate` (#006) stockées en colonnes plates (`begin_year`, `begin_month`, `begin_day`, `begin_precision`, `begin_calendar`, idem `end_*`) pour l'indexation et le tri.
- La géométrie est un `geometry(Point, 4326)` PostGIS, avec provenance tracée (`location_source`) car la majorité des coordonnées sont héritées du lieu (P276 -> P625).
- `sitelink_count` sert de proxy d'importance pour l'affichage par niveau de zoom.

La requête critique du projet (événements dans une bbox et une fenêtre temporelle, ordonnés par importance) impose dès maintenant les index : unique sur `qid`, GiST sur `geom`, btree sur `begin_year`.

L'upsert par lots doit être idempotent (rejouer le même lot ne change pas l'état) et préserver les colonnes d'enrichissement Wikipedia (#012) : un upsert venu de Wikidata ne remplace que les colonnes d'origine Wikidata.

## User Story

> En tant que développeur du pipeline d'ingestion, je veux une API Atlas d'upsert par lots, idempotente et indexée, afin d'importer des centaines de milliers d'événements rejouables sans dupliquer ni écraser les données enrichies.

---

## Tâches

- [ ] Migration : créer la table `atlas.events` (le schéma PG `atlas` existe depuis #001) avec les colonnes :
  - `id` : UUID v7, clé primaire (générateur retenu en #001 pour les binary_id) ;
  - `qid` : string, non nul, contrainte unique ;
  - `label_fr`, `label_en` : string ;
  - `description_fr`, `description_en` : text (descriptions courtes Wikidata) ;
  - `extract_fr`, `extract_en` : text (résumés Wikipedia, remplis par #012, nuls à l'import) ;
  - `wiki_url_fr`, `wiki_url_en` : string ;
  - `kind` : string (classe P31 principale, QID brut à ce stade) ;
  - `begin_year` (integer, non nul), `begin_month`, `begin_day` (integer, nuls), `begin_precision` (integer, non nul), `begin_calendar` (string) ;
  - `end_year`, `end_month`, `end_day`, `end_precision`, `end_calendar` : mêmes types, tous nullables (beaucoup d'événements ponctuels) ;
  - `geom` : `geometry(Point, 4326)` ;
  - `location_source` : string parmi `direct`, `place`, `country` ;
  - `sitelink_count` : integer, non nul, défaut 0 ;
  - timestamps.
- [ ] Migration : index unique `qid`, index GiST `geom`, index btree `begin_year`.
- [ ] Migration : créer la table `atlas.event_links` : `id` UUID v7, `source_id` et `target_id` (références `atlas.events`, `on_delete: :delete_all`), `type` string parmi `part_of`, `follows`, `cause`, `effect`, `significant`, timestamps ; index unique `(source_id, target_id, type)`, index sur `target_id`.
- [ ] Schéma `Amanogawa.Atlas.Event` : `@schema_prefix "atlas"`, `@primary_key {:id, :binary_id, ...}`, `location_source` et `begin_calendar`/`end_calendar` en `Ecto.Enum`, `geom` en `Geo.PostGIS.Geometry` ; changeset validant le format du QID (`~r/^Q\d+$/`), la cohérence des colonnes plates (mêmes invariants de précision que `HistoricalDate` : si precision <= 9, month/day nils) et le SRID 4326.
- [ ] Helpers de conversion sur `Event` : `begin_date/1` et `end_date/1` retournant un `%Amanogawa.HistoricalDate{}` (ou nil) depuis les colonnes plates, et une fonction inverse aplatissant un `HistoricalDate` en attributs `begin_*`/`end_*` (utilisée par l'ingestion et les tests).
- [ ] Schéma `Amanogawa.Atlas.EventLink` : `@schema_prefix "atlas"`, `type` en `Ecto.Enum` (`:part_of`, `:follows`, `:cause`, `:effect`, `:significant`), changeset avec contrainte d'unicité `(source_id, target_id, type)` et interdiction de l'auto-lien (`source_id != target_id`).
- [ ] Façade `Amanogawa.Atlas` :
  - `upsert_events/1` : liste de maps normalisées (attributs plats, dont `qid`), découpe en lots (500 lignes max par `insert_all`, limite des paramètres PostgreSQL), `on_conflict: {:replace, colonnes_wikidata}` avec `conflict_target: :qid`. Les colonnes remplacées excluent `id`, `inserted_at` et les colonnes d'enrichissement (`extract_fr`, `extract_en` et les colonnes ajoutées en #012) ; `updated_at` est remplacé. Retourne `{:ok, %{upserted: n}}`.
  - `upsert_event_links/1` : liste de `%{source_qid, target_qid, type}` ; résolution des QID vers les ids internes en une requête, ignore silencieusement les paires dont un QID est inconnu localement, insertion par lots avec `on_conflict: :nothing`. Retourne `{:ok, %{created: n, skipped_missing: n}}`.
  - `get_event_by_qid/1`, `event_ids_by_qids/1` (map QID -> id), `count_events/0`, `count_event_links/0` (besoins des tests et des métriques de sync).
- [ ] Builder canonique `event_fixture/1` (et `event_link_fixture/1`) dans `test/support/fixtures/atlas_fixtures.ex`, seul point de construction d'événements de test.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : changeset `Event` valide avec date BCE (begin_year -489, precision 9), Point SRID 4326, location_source `:place` ; changeset `EventLink` valide.
- [ ] **Edge case** : événement sans date de fin (colonnes `end_*` nulles) ; événement préhistorique (begin_year -123000, precision 6) ; conversion aller-retour colonnes plates <-> `HistoricalDate`.
- [ ] **Error case** : QID mal formé rejeté ; `begin_month` renseigné avec `begin_precision` 9 rejeté ou tronqué (même règle que #006) ; auto-lien rejeté ; `type` de lien inconnu rejeté.
- [ ] **Limit case** : label et extract très longs acceptés (colonnes text) ; sitelink_count 0.

### Property-based tests (si applicable)

- [ ] **Property** : pour tout `HistoricalDate` généré (générateurs de #006), l'aplatissement en colonnes `begin_*` suivi de `begin_date/1` redonne une date égale (round-trip).

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (fonctions liées à la base ; les fonctions pures de conversion sont couvertes par le property test).

### Tests d'intégration

- [ ] **Intégration (DataCase)** : `upsert_events/1` insère un lot puis, rejoué à l'identique, laisse le nombre de lignes et toutes les colonnes métier inchangés (idempotence).
- [ ] **Intégration (DataCase)** : `upsert_events/1` avec un label modifié met à jour la ligne existante (pas de doublon) ; un `extract_fr` préalablement renseigné n'est pas écrasé par l'upsert Wikidata.
- [ ] **Intégration (DataCase)** : `upsert_events/1` sur un lot de plus de 500 éléments passe (découpage en plusieurs `insert_all`).
- [ ] **Intégration (DataCase)** : `upsert_event_links/1` crée les liens dont les deux QID existent, compte en `skipped_missing` les autres, et rejoué ne crée aucun doublon (contrainte unique + `on_conflict: :nothing`).
- [ ] **Intégration (DataCase)** : la contrainte unique sur `qid` et l'index GiST existent (vérification via une requête sur le catalogue ou par le comportement d'upsert).

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/atlas.ex` (façade publique)
  - `lib/amanogawa/atlas/event.ex`
  - `lib/amanogawa/atlas/event_link.ex`
  - `priv/repo/migrations/NNN_create_atlas_events.exs`
  - `priv/repo/migrations/NNN_create_atlas_event_links.exs`
  - `test/amanogawa/atlas_test.exs`
  - `test/amanogawa/atlas/event_test.exs`
  - `test/amanogawa/atlas/event_link_test.exs`
  - `test/support/fixtures/atlas_fixtures.ex`
- **Documentation de référence** : `.claude/memory/domain-model.md`, ADR 0006 (colonnes plates), ADR 0007 (PostGIS), `.claude/rules/architecture.md` (façades, `@schema_prefix`), `.claude/rules/geo-temporal.md`.
- **Compétences requises** : Ecto `insert_all`/`on_conflict`, migrations multi-schémas PG, geo_postgis, contraintes et index PostGIS.
- **Points d'attention** :
  - `insert_all` ne passe pas par les changesets : valider ou normaliser les lots en amont (l'ingestion livre des données déjà normalisées par #009), et laisser les contraintes DB comme filet.
  - Limite PostgreSQL de 65 535 paramètres par requête : avec une vingtaine de colonnes, rester à 500 lignes par lot.
  - La liste des colonnes remplacées par l'upsert est un point de contrat avec #012 : la centraliser dans un attribut de module documenté (`@wikidata_columns`).
  - `location_source` accepte `:country` (prévu au modèle de domaine) même si l'ingestion F02 ne produit que `:direct` et `:place`.
  - Jamais de type `date` PostgreSQL pour les colonnes temporelles.
  - `kind` reste le QID brut de la classe P31 à ce stade ; le mapping vers des libellés lisibles est un sujet d'affichage, hors périmètre.
