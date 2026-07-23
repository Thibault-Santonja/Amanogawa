# Issue #023 -- Schémas Polity/Border et import Cliopatria

**Feature :** F05 -- Frontières historiques
**Priorité :** Haute
**Estimation :** 16h
**Prérequis :** #001, #007

---

## Contexte

F05 affiche les zones d'influence des entités politiques selon l'année sélectionnée. Cette issue pose le socle de données : les tables `atlas.polities` et `atlas.borders`, puis l'import du dataset Cliopatria (Seshat Global History Databank), retenu par l'ADR 0004 comme socle mondial : CC BY 4.0, couverture -3400 à 2024, 1600+ entités politiques, ~14 000 polygones datés, GeoJSON ~307 Mo en EPSG:4326, publié sur Zenodo (v0.1.3, record 14714684).

Le problème résolu : disposer en PostGIS de polygones datés, valides, simplifiés et requêtables par année (`from_year <= A AND to_year >= A`), conformément à l'ADR 0007 (stockage PostGIS SRID 4326, simplification à l'import pour tenir le budget de payload, diffusion GeoJSON à la bordure web uniquement).

Insertion dans l'architecture : les schémas et les upserts vivent dans le contexte Atlas (read model, façade `Amanogawa.Atlas`) ; le pipeline de lecture, validation et transformation vit dans le contexte Ingestion et écrit dans Atlas uniquement via sa façade publique. L'import est déclenché par une mix task (pas d'Oban ici : opération ponctuelle, fichier local, pas de raison runtime).

Impact sur le reste du système : l'issue #024 (historical-basemaps) réutilise ce pipeline et ces tables ; l'issue #025 (endpoint `/api/borders` et rendu MapLibre) lit ces tables. Le niveau de simplification par défaut choisi ici conditionne directement le budget payload de #025 (cible < 1.5 Mo gzip par année).

## User Story

> En tant que mainteneur du projet, je veux importer les polygones datés de Cliopatria dans PostGIS, validés et simplifiés, afin que l'application puisse servir les zones d'influence actives pour n'importe quelle année entre -3400 et 2024.

---

## Tâches

- [ ] Migration `atlas.polities` : `id` UUID v7 (pk), `name` (text, not null), `from_year` et `to_year` (integer, nullables : période d'existence de l'entité, années astronomiques signées), `source` (text, not null), timestamps ; contrainte unique sur `(name, source)`.
- [ ] Migration `atlas.borders` : `id` UUID v7 (pk), `polity_id` (fk vers `atlas.polities`, `on_delete: :delete_all`), `geom geometry(MultiPolygon, 4326)` (not null, géométrie validée de référence), `geom_medium` et `geom_low` (`geometry(MultiPolygon, 4326)`, niveaux simplifiés), `from_year` et `to_year` (integer, not null, signés), `source` (text, not null), `precision` (integer, nullable), timestamps ; contrainte check `from_year <= to_year`.
- [ ] Index : GiST sur `geom`, `geom_medium`, `geom_low` ; btree composite `(from_year, to_year)` ; btree `polity_id`.
- [ ] Schémas Ecto `Amanogawa.Atlas.Polity` et `Amanogawa.Atlas.Border` avec `@schema_prefix "atlas"`, types `Geo.PostGIS.Geometry`, changesets (validation `from_year <= to_year`, `source` obligatoire). Jamais de type `date` PostgreSQL.
- [ ] Façade `Amanogawa.Atlas` : `upsert_polity/1` (clé naturelle `(name, source)`) et `replace_borders/2` (purge transactionnelle des lignes d'une `source` puis réinsertion) ; requêtes SQL et fragments PostGIS centralisés dans le module de requêtes du contexte (chercher l'existant avant de créer).
- [ ] Trancher la bibliothèque de streaming JSON : comparer Jaxon et les alternatives de parsing en flux (critères : mémoire constante sur 307 Mo, maintenance, API Stream Elixir). Charger le fichier entier en mémoire est interdit. Documenter la décision dans `.claude/memory/tech-stack.md`.
- [ ] Parser Ingestion : lecture en streaming du GeoJSON Cliopatria, mapping des propriétés (`Name`, `FromYear`, `ToYear`, autres champs utiles) vers des structs de domaine ; vérifier sur l'échantillon réel que les années sont bien des entiers signés en convention astronomique et normaliser sinon.
- [ ] Validation des géométries à l'insertion : `ST_MakeValid`, extraction des composantes surfaciques (`ST_CollectionExtract(..., 3)`), conversion en MultiPolygon (`ST_Multi`) ; rejeter et journaliser les géométries vides après réparation (compteur en fin d'import).
- [ ] Simplification par niveaux avec `ST_SimplifyPreserveTopology` pour remplir `geom_medium` et `geom_low` : tolérances à calibrer (point de départ suggéré : 0.01 et 0.05 degré), revalider les géométries après simplification. Mesurer la taille résultante pour quelques années témoins et documenter le budget payload obtenu dans l'issue (la mesure de bout en bout gzip est finalisée dans #025, cible < 1.5 Mo gzip par année au niveau par défaut).
- [ ] Idempotence : l'import complet s'exécute dans une transaction, purge puis réinsertion par `source = "cliopatria"` ; un ré-import produit exactement le même état final (mêmes comptes de lignes, pas de doublons).
- [ ] Mix task `mix amanogawa.import.cliopatria PATH` : vérification de l'existence du fichier, progression, résumé final (polities créées, borders insérées, géométries réparées, rejets). Le téléchargement est manuel et documenté dans le `@moduledoc` de la task : URL Zenodo v0.1.3 (record 14714684), taille ~307 Mo, licence CC BY 4.0, ne jamais committer le dataset.
- [ ] Documenter l'obligation d'attribution CC BY 4.0 (reprise dans les crédits carte en #025 et la page Sources en F06).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : le parser transforme une fixture de quelques features Cliopatria en structs de domaine complets (nom, from_year, to_year, géométrie).
- [ ] **Edge case** : une feature de type `Polygon` simple est acceptée et destinée à devenir `MultiPolygon` ; années négatives correctement signées ; propriétés superflues ignorées.
- [ ] **Error case** : JSON malformé ou propriété obligatoire manquante (`Name`, `FromYear`, `ToYear`) produit une erreur taguée `{:error, ...}` sans crash du flux entier ; le changeset refuse `from_year > to_year`.
- [ ] **Limit case** : `from_year == to_year` accepté ; bornes du dataset (-3400 et 2024) acceptées.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout couple d'années signées générées, la normalisation du parser produit soit une paire ordonnée `from_year <= to_year`, soit une erreur taguée ; jamais d'exception.
- [ ] **Property** (StreamData) : le parser ne lève jamais d'exception sur des propriétés de feature aléatoirement absentes ou de mauvais type (erreurs taguées uniquement).

### Doctests (si applicable)

- [ ] **Doctest** : fonction pure de mapping d'une feature vers les attributs de Border (exemple minimal dans le `@moduledoc` du parser).

### Tests d'intégration

- [ ] **Intégration** (DataCase, PostGIS réel) : l'import d'une fixture GeoJSON crée polities et borders ; SRID 4326 vérifié ; `ST_IsValid` vrai sur `geom`, `geom_medium`, `geom_low` ; niveaux simplifiés non nuls.
- [ ] **Intégration** : une fixture contenant une géométrie invalide (auto-intersection) est réparée par `ST_MakeValid` et insérée valide ; une géométrie irrécupérable (vide après réparation) est rejetée et comptée.
- [ ] **Intégration** : deux exécutions successives de l'import donnent le même état final (idempotence : comptes identiques, unicité `(name, source)` respectée).
- [ ] **Intégration** : la mix task s'exécute sur la fixture et affiche un résumé cohérent avec l'état en base.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable, cette issue ne comporte pas d'interface utilisateur (le rendu est couvert par #025).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `priv/repo/migrations/<timestamp>_create_polities_and_borders.exs` (nouveau)
  - `lib/amanogawa/atlas/polity.ex`, `lib/amanogawa/atlas/border.ex` (nouveaux)
  - `lib/amanogawa/atlas.ex` (façade, à compléter)
  - module de requêtes du contexte Atlas (compléter l'existant issu de #007, sinon `lib/amanogawa/atlas/border_queries.ex`)
  - `lib/amanogawa/ingestion.ex` (façade, à compléter), `lib/amanogawa/ingestion/cliopatria/parser.ex`, `lib/amanogawa/ingestion/cliopatria/importer.ex` (nouveaux)
  - `lib/mix/tasks/amanogawa.import.cliopatria.ex` (nouveau)
  - `test/amanogawa/ingestion/cliopatria/parser_test.exs`, `test/amanogawa/atlas_test.exs` (compléter), `test/mix/tasks/amanogawa.import.cliopatria_test.exs`
  - `test/support/fixtures/cliopatria/sample.geojson` (extrait de quelques features réelles, dont une géométrie invalide et un Polygon simple)
- **Documentation de référence** : ADR 0004 (choix Cliopatria), ADR 0007 (PostGIS, simplification, budget payload), `.claude/memory/data-sources.md` et `.claude/memory/domain-model.md`, `docs/studies/2026-07-sources-donnees-historiques.md` (section 3), dépôt GitHub Seshat-Global-History-Databank/cliopatria, Zenodo record 14714684.
- **Compétences requises** : Ecto et geo_postgis (types PostGIS dans les schémas), fonctions PostGIS via fragments (`ST_MakeValid`, `ST_SimplifyPreserveTopology`, `ST_Multi`, `ST_CollectionExtract`), parsing JSON en streaming, mix tasks.
- **Points d'attention** :
  - SRID 4326 partout ; GeoJSON uniquement à la bordure web (pas dans cette issue).
  - La mix task appelle exclusivement les façades `Amanogawa.Ingestion` et `Amanogawa.Atlas` : aucun accès `Repo` ni module interne hors contexte.
  - `ST_SimplifyPreserveTopology` peut produire des géométries invalides : revalider après simplification.
  - Mémoire bornée : le flux doit traiter les 307 Mo feature par feature, insertions par lots.
  - Années astronomiques signées, jamais de `date` PostgreSQL (règle projet).
  - Aucun appel réseau dans les tests : tout passe par des fixtures locales.
  - Ne pas committer le dataset ; documenter un chemin de travail local (et l'ignorer via git si besoin).
