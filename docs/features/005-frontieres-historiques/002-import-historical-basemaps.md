# Issue #024 -- Import historical-basemaps (préhistoire)

**Feature :** F05 -- Frontières historiques
**Priorité :** Moyenne
**Estimation :** 8h
**Prérequis :** #023

---

## Contexte

Cliopatria (#023) couvre -3400 à 2024. Pour les années antérieures, l'ADR 0004 retient historical-basemaps d'A. Ourednik (dépôt GitHub `aourednik/historical-basemaps`, licence GPL-3.0) : un fichier GeoJSON par tranche temporelle (par exemple `world_bc123000.geojson`, `world_bc10000.geojson`, ...), précision volontairement grossière signalée par le champ `BORDERPRECISION`, à présenter comme zones d'influence.

Le problème résolu : peupler `atlas.polities` et `atlas.borders` pour les années strictement inférieures à -3400, sans chevauchement ni fusion avec Cliopatria à la jonction (règle F05 : historical-basemaps sert uniquement les années < -3400). Chaque tranche est un instantané : il faut la convertir en intervalle `from_year`/`to_year` pour que la requête "frontières actives à l'année A" reste un simple filtre indexé.

Insertion dans l'architecture : réutilisation du pipeline d'import de #023 (lecture GeoJSON, validation `ST_MakeValid`, simplification par niveaux, idempotence par purge de la source) avec un parser propre au format historical-basemaps, dans le contexte Ingestion, écrivant via la façade `Amanogawa.Atlas`. Une mix task dédiée déclenche l'import.

Impact sur le reste du système : l'endpoint #025 sert ces polygones de manière transparente (même table, même requête) ; l'attribution GPL-3.0 doit être visible dans les crédits carte (#025) et détaillée sur la page Sources (F06 #027).

## User Story

> En tant que mainteneur du projet, je veux importer les tranches préhistoriques de historical-basemaps afin que la carte affiche des zones d'influence pour les années antérieures à -3400, sans chevauchement avec Cliopatria.

---

## Tâches

- [ ] Documenter le téléchargement manuel dans le `@moduledoc` de la mix task : clone du dépôt GitHub `aourednik/historical-basemaps` (ou récupération des seuls GeoJSON concernés), licence GPL-3.0, ne jamais committer les données.
- [ ] Recenser les tranches strictement antérieures à -3400 présentes dans le dépôt au moment de l'import (attendu : -123000, -10000, -8000, -5000, -4000 ; vérifier la liste réelle, les noms de fichiers du dépôt peuvent évoluer) et documenter le recensement dans l'issue au moment de l'implémentation.
- [ ] Mapping tranches vers intervalles : pour des tranches triées `a1 < a2 < ... < an` (toutes < -3400), `from_year = ai` et `to_year = a(i+1) - 1` ; la dernière tranche utilisée est bornée à `to_year = -3401` (jonction Cliopatria exclusive). Fonction pure, table de correspondance explicite et testée.
- [ ] Exclusion stricte : toute tranche >= -3400 est ignorée (journalisée, jamais importée).
- [ ] Parser des propriétés historical-basemaps : `NAME` vers `Polity.name` (source `"historical_basemaps"`), `BORDERPRECISION` vers `Border.precision` ; tolérer les features sans nom (les journaliser et les écarter).
- [ ] Réutiliser la chaîne de #023 : validation `ST_MakeValid` + conversion MultiPolygon, simplification `ST_SimplifyPreserveTopology` (`geom_medium`, `geom_low`), insertion via `Amanogawa.Atlas.replace_borders/2`. Si du code est dupliqué entre les deux parsers, extraire un module commun dans le contexte Ingestion plutôt que copier.
- [ ] Idempotence : purge transactionnelle de la source `"historical_basemaps"` puis réinsertion ; le ré-import ne touche pas aux lignes Cliopatria.
- [ ] Mix task `mix amanogawa.import.historical_basemaps PATH` : `PATH` est le dossier contenant les GeoJSON ; découverte des fichiers, filtrage des tranches, progression, résumé final (tranches importées, tranches ignorées, features écartées).
- [ ] Documenter l'attribution : GPL-3.0 s'applique aux données importées, compatible avec l'AGPL-3.0 du projet (ADR 0004) ; mention à reprendre dans les crédits carte (#025) et à détailler sur la page Sources (F06 #027).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : le mapping de tranches triées `[-123000, -10000, -8000, -5000, -4000]` produit des intervalles contigus, le dernier borné à `to_year = -3401`.
- [ ] **Edge case** : une seule tranche fournie produit l'intervalle `[année, -3401]` ; features sans `NAME` écartées sans crash ; `BORDERPRECISION` absent donne `precision` nil.
- [ ] **Error case** : nom de fichier ne correspondant pas au motif attendu produit une erreur taguée ; GeoJSON malformé produit une erreur taguée.
- [ ] **Limit case** : une tranche exactement à -3400 est exclue ; une tranche à -3401 est incluse avec `from_year = to_year = -3401`.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute liste strictement croissante d'années < -3400, les intervalles produits sont contigus, sans chevauchement, et leur union couvre exactement `[première tranche, -3401]`.

### Doctests (si applicable)

- [ ] **Doctest** : fonction de mapping tranches vers intervalles (exemple canonique dans le `@moduledoc`).

### Tests d'intégration

- [ ] **Intégration** (DataCase, PostGIS réel) : l'import d'une fixture de deux tranches crée les borders avec les bons intervalles, `precision` renseignée depuis `BORDERPRECISION`, géométries valides en SRID 4326, niveaux simplifiés remplis.
- [ ] **Intégration** : après import, aucune ligne de source `"historical_basemaps"` n'a `from_year >= -3400`.
- [ ] **Intégration** : ré-import idempotent ; des lignes Cliopatria préexistantes (fixture) restent intactes après purge et réinsertion de la source historical-basemaps.
- [ ] **Intégration** : la mix task s'exécute sur un dossier de fixtures et son résumé est cohérent avec l'état en base.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable, pas d'interface utilisateur dans cette issue (le rendu est couvert par #025).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion/historical_basemaps/parser.ex`, `lib/amanogawa/ingestion/historical_basemaps/importer.ex` (nouveaux)
  - module commun éventuel extrait de #023 (par exemple `lib/amanogawa/ingestion/borders/geometry_pipeline.ex`) : chercher l'existant avant de créer
  - `lib/amanogawa/ingestion.ex` (façade, à compléter)
  - `lib/mix/tasks/amanogawa.import.historical_basemaps.ex` (nouveau)
  - `test/amanogawa/ingestion/historical_basemaps/parser_test.exs`, `test/mix/tasks/amanogawa.import.historical_basemaps_test.exs`
  - `test/support/fixtures/historical_basemaps/` (deux tranches minimales extraites du vrai dataset, avec `BORDERPRECISION`, une feature sans nom, une géométrie invalide)
- **Documentation de référence** : ADR 0004 (jonction -3400, compatibilité GPL/AGPL), `.claude/memory/data-sources.md`, `docs/studies/2026-07-sources-donnees-historiques.md` (section 3), dépôt GitHub `aourednik/historical-basemaps`, issue #023 (pipeline réutilisé).
- **Compétences requises** : Ecto/PostGIS (acquis en #023), manipulation de fichiers et découverte de dossier en Elixir, mix tasks.
- **Points d'attention** :
  - Jonction exclusive : -3400 appartient à Cliopatria ; historical-basemaps s'arrête à -3401. Aucune fusion des deux sources sur une même année.
  - Fichiers bien plus petits que Cliopatria, mais conserver le même chemin de lecture en flux : un seul pipeline à maintenir.
  - Précision volontairement grossière : ce sont des zones d'influence, pas des frontières ; le champ `precision` doit être conservé pour que l'UI (#025) puisse l'assumer visuellement.
  - Idempotence par source : la purge est filtrée sur `source = "historical_basemaps"`, jamais globale.
  - Aucun appel réseau dans les tests ; aucune donnée du dataset committée.
