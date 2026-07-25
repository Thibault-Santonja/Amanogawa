# Issue #034 -- Contexte Contributions : surcouche, révisions et résolution

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 14h
**Prérequis :** #033 (F07 livrée : contexte Accounts complet)

---

## Contexte

Première issue de F08 : poser le quatrième et dernier bounded context, `Contributions`, et le socle de données en couches sur lequel toute la feature repose. Le principe directeur est non négociable (vue d'ensemble F08, ADR 0008) : les données Wikidata restent traçables et resynchronisables, les contributions locales vivent en surcouche, jamais d'écrasement silencieux dans un sens ni dans l'autre.

Trois tables dans le schéma PG `contributions` (séparation par contexte, `.claude/rules/architecture.md`) :

- `contributions.overrides` : une ligne par correction proposée. Pour une correction de champ (`kind: :field`) : une ligne par champ corrigé par événement (`event_qid`, `field` parmi `label_fr`, `label_en`, `begin_date`, `end_date`, `position`), valeur proposée en jsonb typé, snapshot de la valeur courante au moment de la proposition (`current_value`, pour le diff de relecture), snapshot de la valeur Wikidata à l'acceptation (`wikidata_value_at_acceptance`, pour la détection de divergences en #035 et la réversibilité), source ou justification OBLIGATOIRE (URL ou référence textuelle, bornée), statut (`:pending`, `:accepted`, `:rejected`, `:superseded`), `author_id` (uuid, SANS foreign key vers `accounts.users` : pas de FK entre schémas de contextes différents, et l'anonymisation de #038 mettra ce champ à nil). Deux autres kinds portés par la même table : `:link` (ajout d'un lien typé : `target_qid` + type parmi les cinq d'`Amanogawa.Atlas.EventLink`) et `:new_event` (payload complet d'un événement proposé : libellés, date de début avec précision, position, description optionnelle).
- `contributions.revisions` : historique append-only. Une ligne par action (`:proposed`, `:accepted`, `:rejected`, `:appealed`, `:appeal_reviewed`, `:superseded`, `:anonymized`), avec `override_id` (FK interne au schéma, autorisée), `actor_id` (nullable), message public (motif de décision, texte d'appel), `inserted_at` seul (pas d'`updated_at` : on n'édite jamais une révision). Aucune fonction de mise à jour ni de suppression dans le contexte : le caractère append-only est une propriété de l'API, testée.
- `contributions.conflicts` : divergences détectées par la sync (#035) entre la nouvelle valeur Wikidata et le snapshot d'un override accepté. Colonnes : `override_id`, `event_qid`, `field`, `wikidata_value` (jsonb, la valeur divergente), `detected_at`, `status` (`:open`, `:resolved`), `resolution` (`:kept_override`, `:adopted_wikidata`), `resolved_by`, `resolved_at`. Index partiel unique sur `override_id WHERE status = 'open'` : une seule divergence ouverte par override, mise à jour si Wikidata change encore. Cette issue crée la table et le schéma Ecto ; le remplissage et l'examen arrivent en #035.

### Mécanisme de résolution de la valeur affichée (tranché)

La valeur affichée = override accepté sinon valeur Wikidata. Trois mécanismes ont été pesés :

1. **Vue matérialisée** : duplique toute `atlas.events` pour une fraction de lignes corrigées, impose d'orchestrer des rafraîchissements (staleness entre acceptation et REFRESH) et de re-pointer tous les index critiques (begin_year, GiST geom). Rejeté.
2. **Jointure à la lecture** : ferait payer à LA requête critique du projet (viewport carte, < 300 ms p95, `Amanogawa.Atlas.EventQueries`) un pivot cross-schéma sur une table en une-ligne-par-champ, à chaque déplacement de carte, pour un cas rare. Rejeté.
3. **Colonne résolue maintenue par Contributions via l'API publique d'Atlas** : à l'acceptation, Contributions appelle Atlas qui écrit la valeur corrigée dans les colonnes existantes d'`atlas.events` et marque le champ dans une nouvelle colonne `overridden_fields` (text[], noms de champs métier). RETENU : les écritures d'override sont rares, les lectures sont le chemin chaud ; résoudre à l'écriture laisse le chemin de lecture strictement inchangé (zéro coût, zéro staleness), et la couche reste traçable car la valeur Wikidata d'origine est snapshotée dans l'override et le champ est marqué. La frontière de contextes est respectée : Contributions ne touche `atlas.events` qu'à travers `Amanogawa.Atlas.apply_field_override/3` et `release_field_override/3`, jamais par `Repo` ni par les modules internes d'Atlas.

Cette décision structurante sera actée dans l'ADR 0009 (rédigé en #039).

### Modifications d'Atlas et d'Accounts (fondations des issues suivantes)

- `atlas.events` : colonne `overridden_fields` (text[], défaut `{}`), colonne `origin` (`:wikidata` | `:contribution`, défaut `:wikidata`), valeur d'enum `:contribution` ajoutée à `location_source` (une position corrigée par un humain est une provenance supplémentaire, vue d'ensemble F08). Format d'identifiant public étendu : la colonne `qid` accepte aussi `L<uuid hex>` pour les événements d'origine communautaire (jamais en collision avec `Q\d+`, donc invisible pour les upserts Wikidata dont la cible de conflit est `qid`) ; regex de `Amanogawa.Atlas.Event.changeset/2` et de `AmanogawaWeb.Params.EventId` étendues.
- `accounts.users` : colonnes `role` (`:user` | `:reviewer`, défaut `:user`, promotion manuelle en base pour commencer) et `display_name` (pseudonyme public, nullable, unique en casse insensible, 3 à 40 caractères) ; façade `Amanogawa.Accounts` : `reviewer?/1`, `set_display_name/2`, `display_names_by_ids/1` (résolution des attributions côté web sans exposer les emails). Le scope (`Amanogawa.Accounts.Scope`) porte le rôle.

Impact système : aucune UI dans cette issue ; elle livre le contexte, ses migrations et la résolution, consommés par #035 (sync), #036 (propositions), #037 (décisions).

## User Story

> En tant que développeur des issues suivantes de F08, je veux un contexte Contributions complet (surcouche, historique append-only, résolution via l'API publique d'Atlas) afin de bâtir formulaire, relecture et transparence sans jamais violer le principe des données en couches.

---

## Tâches

- [ ] Migrations : création du schéma PG `contributions` (`CREATE SCHEMA`), tables `overrides`, `revisions`, `conflicts` (colonnes ci-dessus, uuid v7 en clés primaires, index : `overrides (event_qid)`, `overrides (author_id)`, `overrides (status, inserted_at)`, index partiel unique `overrides (event_qid, field) WHERE status = 'accepted' AND kind = 'field'` (un seul override accepté par champ et par événement), `revisions (override_id, inserted_at)`, index partiel unique `conflicts (override_id) WHERE status = 'open'`).
- [ ] Migrations Atlas : `overridden_fields text[] NOT NULL DEFAULT '{}'` et `origin` sur `atlas.events` ; pas de contrainte SQL sur le format de `qid` (le format est vérifié en changeset, comme aujourd'hui).
- [ ] Migration Accounts : `role` et `display_name` (index unique sur `lower(display_name)`) sur `accounts.users` ; extension du schéma `Amanogawa.Accounts.User`, de `Amanogawa.Accounts.Scope`, et fonctions de façade `reviewer?/1`, `set_display_name/2` (validation longueur et unicité), `display_names_by_ids/1`.
- [ ] Schémas Ecto internes `Amanogawa.Contributions.Override`, `Amanogawa.Contributions.Revision`, `Amanogawa.Contributions.Conflict` (`@schema_prefix "contributions"`), changesets avec validations : `field` dans la liste fermée, justification obligatoire bornée (5 à 1000 caractères), payloads jsonb validés par type de champ (date via `Amanogawa.HistoricalDate.changeset/2` rejouée sur le payload, position en Point SRID 4326 borné au monde, libellé non vide borné, lien avec `target_qid` au format valide et type dans l'enum d'`EventLink`).
- [ ] Façade `Amanogawa.Contributions` (seul module appelé de l'extérieur) : `propose/2` (attrs + auteur ; écrit l'override `:pending` ET sa révision `:proposed` dans une transaction), `get_override/1`, `list_overrides/1` (filtres factuels : statut, event_qid, auteur ; ordre strictement chronologique, pagination keyset), `list_revisions/1`, `accept_override/3` et `reject_override/3` (relecteur + motif public obligatoire : vérifient le rôle via la valeur passée par l'appelant ET refusent un auteur qui se relit lui-même ; l'acceptation snapshote `wikidata_value_at_acceptance` depuis l'événement courant, appelle `Amanogawa.Atlas.apply_field_override/3` (ou `upsert_event_links/1` pour un `:link`, `create_contributed_event/1` pour un `:new_event`) et journalise la révision, le tout transactionnellement), `count_by_status/0`.
- [ ] API publique Atlas : `apply_field_override(qid, field, value)` (écrit les colonnes du champ métier : `begin_date` couvre `begin_year..begin_calendar`, `position` couvre `geom` + `location_source: :contribution` ; ajoute le champ à `overridden_fields`), `release_field_override(qid, field, wikidata_value)` (restaure la valeur Wikidata fournie, retire le marqueur), `create_contributed_event(attrs)` (génère l'identifiant `L<uuid hex>`, `origin: :contribution`, valide par `Event.changeset/2`). Le mapping champ métier -> colonnes vit à UN endroit (module interne d'Atlas), réutilisé par #035.
- [ ] Résolution en lecture : rien à faire par construction (les lectures existantes servent la valeur résolue) ; documenter cette propriété dans le moduledoc de la façade `Amanogawa.Contributions` et dans celui d'`Amanogawa.Atlas.apply_field_override/3`.
- [ ] Aucune fonction d'update ni de delete sur `revisions` dans tout le contexte (append-only par API) ; le moduledoc de `Revision` l'affirme et un test le vérifie par introspection des fonctions exportées de la façade.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `propose/2` crée un override `:pending` et une révision `:proposed` attribuée ; `accept_override/3` passe l'override à `:accepted`, snapshote la valeur Wikidata, journalise la révision avec le motif, et la valeur lue via `Amanogawa.Atlas.get_event_by_qid/1` est la valeur corrigée avec le champ marqué dans `overridden_fields`.
- [ ] **Happy path** : `release_field_override/3` restaure exactement la valeur passée et retire le marqueur ; l'événement redevient indistinguable d'un événement jamais corrigé.
- [ ] **Edge case** : `propose/2` sur `end_date` avec valeur proposée nulle (retirer une date de fin erronée) est accepté par le changeset ; `propose/2` sans justification, ou avec une justification de 1001 caractères, est rejeté.
- [ ] **Error case** : `accept_override/3` par un non-relecteur, ou par l'auteur de l'override, retourne une erreur taguée et ne modifie ni l'override ni `atlas.events` ; payload de position hors bornes monde ou SRID manquant rejeté ; `field` hors liste fermée rejeté.
- [ ] **Limit case** : deux overrides acceptés pour le même `(event_qid, field)` : le second échoue sur l'index partiel unique ; deux acceptations concurrentes du même override n'appliquent qu'une écriture Atlas (transaction + rechargement du statut).
- [ ] **Limit case** : `create_contributed_event/1` génère un identifiant `L<uuid hex>` accepté par le changeset étendu, et `Q123` reste accepté ; un format tiers (`X1`, `Q12x`) reste rejeté.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute `HistoricalDate` valide générée, l'aller-retour payload jsonb de l'override (encodage à la proposition, décodage à l'application) restitue une date identique champ à champ, précision comprise (le modèle temporel ne perd jamais la précision, règle géo-temporelle).
- [ ] **Property** (StreamData) : pour toute séquence d'actions valides (propose, accept, release) sur un événement, la valeur lue est toujours soit la dernière valeur appliquée, soit la valeur Wikidata d'origine, jamais un état intermédiaire (invariant "override accepté sinon Wikidata").

### Doctests (si applicable)

- [ ] **Doctest** : moduledoc de la façade sur une fonction pure s'il en existe une (par exemple la normalisation d'un payload) ; sinon non applicable, les fonctions touchent la base.

### Tests d'intégration

- [ ] **Intégration (DataCase)** : parcours complet contre PostGIS : proposition sur `begin_date` -> acceptation -> lecture via `Amanogawa.Atlas.list_events_geojson/1` (la feature viewport porte l'année corrigée) -> release -> la feature reporte l'année Wikidata.
- [ ] **Intégration (DataCase)** : acceptation d'un `:new_event` : la ligne `atlas.events` existe avec `origin: :contribution`, apparaît dans le viewport, et `Amanogawa.Ingestion` peut rejouer un upsert Wikidata sans jamais la toucher (aucun conflit de `qid`).
- [ ] **Intégration (DataCase)** : acceptation d'un `:link` : le lien apparaît via `Amanogawa.Atlas.list_event_links_geojson/1` ; rejouer l'acceptation est idempotent (unique `(source, target, type)`).

### Tests end-to-end (si applicable)

- [ ] Non applicable : aucune UI dans cette issue (parcours E2E en #039).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `priv/repo/migrations/*` (schéma `contributions`, colonnes `atlas.events`, colonnes `accounts.users`)
  - `lib/amanogawa/contributions.ex` (façade), `lib/amanogawa/contributions/override.ex`, `revision.ex`, `conflict.ex`, `lib/amanogawa/contributions/override_queries.ex` (si les requêtes le justifient)
  - `lib/amanogawa/atlas.ex` (`apply_field_override/3`, `release_field_override/3`, `create_contributed_event/1`), `lib/amanogawa/atlas/event.ex` (regex qid, `origin`, `overridden_fields`, `:contribution` dans `location_source`), module interne de mapping champ métier -> colonnes
  - `lib/amanogawa/accounts.ex`, `lib/amanogawa/accounts/user.ex`, `lib/amanogawa/accounts/scope.ex`
  - `lib/amanogawa_web/params/event_id.ex` (format `L<uuid hex>`)
  - `test/amanogawa/contributions_test.exs`, extensions de `test/amanogawa/atlas_test.exs` et `test/amanogawa/accounts_test.exs`, `test/support/fixtures/` (builder canonique d'override)
- **Documentation de référence** : vue d'ensemble F08 (principes directeurs, arbitrages du découpage), ADR 0006 (HistoricalDate), ADR 0008, `.claude/rules/architecture.md` (façades, FK intra-contexte seulement), `.claude/rules/geo-temporal.md`, `.claude/memory/domain-model.md`.
- **Compétences requises** : Ecto (schémas multi-préfixes, index partiels, jsonb, transactions), PostGIS (Point 4326), conception d'API de contexte, modèle temporel du projet.
- **Points d'attention** :
  - JAMAIS de FK entre `contributions` et `atlas`/`accounts` : `event_qid` et `author_id` sont des références sans contrainte, la cohérence est applicative (l'événement est vérifié existant au moment de la proposition).
  - `apply_field_override/3` doit être la SEULE porte d'écriture de Contributions vers Atlas ; aucun `Repo` ni module interne d'Atlas appelé depuis Contributions (revue de code attentive, c'est LE point où la frontière casse facilement).
  - Le snapshot `wikidata_value_at_acceptance` se prend au moment de l'acceptation (valeur alors en base), pas à la proposition : entre les deux, une sync a pu passer.
  - `begin_date` et `position` sont des champs métier composites : ne jamais marquer ni écrire une colonne isolée (`begin_year` sans sa précision) ; passer par le mapping centralisé.
  - Les révisions sont publiques par destination : aucun contenu non public (email, IP) ne doit y entrer, dès le schéma.
  - Uuid v7 (`Ecto.UUID, autogenerate: [version: 7]`) comme partout ailleurs ; timestamps `:utc_datetime`.
