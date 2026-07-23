# Issue #014 -- Endpoint events GeoJSON borné et requête critique

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #010 (worker Oban d'import des événements)

---

## Contexte

La carte MapLibre (hook `MapHook`) ne reçoit pas les événements via les diffs LiveView : les gros volumes transitent par des endpoints JSON dédiés appelés par le hook (ADR 0005, ADR 0007). Cette issue crée le premier et le plus critique de ces endpoints : `GET /api/events?bbox=&from=&to=&limit=`, qui sert les événements du viewport et de la fenêtre temporelle courante, classés par importance.

Le contrôleur Phoenix reste mince : il parse et valide les paramètres, puis délègue à `Amanogawa.Atlas.list_events_geojson/1`, nouvelle fonction de l'API publique du contexte Atlas. La conversion PostGIS vers GeoJSON se fait au bord web (règle : PostGIS en base, GeoJSON à la frontière).

C'est LA requête critique du projet (bbox + fenêtre temporelle + importance sur ~420 000 événements). Elle doit tenir moins de 300 ms au p95 sur le corpus complet : les index composites sont dimensionnés et vérifiés par `EXPLAIN ANALYZE` dans le cadre de cette issue, pas après coup.

L'endpoint est public, read-only, sans effet de bord, et rate limité (Hammer) conformément aux règles de sécurité.

## User Story

> En tant que visiteur de la carte, je veux que les événements de ma vue (zone visible et période choisie) se chargent vite et par ordre d'importance, afin d'explorer l'histoire de façon fluide sans être noyé sous les événements mineurs.

---

## Tâches

- [ ] Ajouter la dépendance `hammer` (rate limiting) dans `mix.exs` et sa configuration (backend ETS en dev/test, configurable via `runtime.exs`).
- [ ] Créer le plug `AmanogawaWeb.Plugs.RateLimit` (Hammer, par IP, fenêtre et quota configurables, réponse 429 JSON avec `retry-after`) et l'appliquer au pipeline `:api`.
- [ ] Déclarer la route `GET /api/events` dans `router.ex` (pipeline `:api`, scope `/api`).
- [ ] Créer `AmanogawaWeb.Params.EventsQuery` : changeset schemaless qui parse et valide les paramètres bruts :
  - `bbox` : chaîne `min_lon,min_lat,max_lon,max_lat` (4 floats), latitudes dans [-90, 90], longitudes dans [-180, 180], `min_lat < max_lat` ; si `min_lon > max_lon`, la bbox traverse l'antiméridien et est décomposée en deux enveloppes `[min_lon, 180]` et `[-180, max_lon]` ; absente : monde entier.
  - `from` / `to` : entiers signés (années astronomiques) dans [-13_800_000_000, année courante], `from <= to` ; absents : plage complète.
  - `limit` : entier, plafonné serveur à 2000, défaut 500 ; toute valeur hors bornes est rejetée ou tronquée au plafond (tronquée : le client ne doit pas pouvoir provoquer une erreur en demandant trop).
  - Paramètre invalide : erreur structurée (champ, message), jamais d'exception.
- [ ] Créer `AmanogawaWeb.Controllers.Api.EventController` (action `index`) : parse via `EventsQuery`, 400 JSON `%{errors: %{champ: [messages]}}` si invalide, sinon délégation à `Amanogawa.Atlas.list_events_geojson/1` et réponse 200 `application/json`.
- [ ] Ajouter `Amanogawa.Atlas.list_events_geojson/1` à l'API publique du contexte : reçoit les options normalisées (`bbox` sous forme d'une ou deux enveloppes, `from`, `to`, `limit`), retourne une map `FeatureCollection` GeoJSON encodable par Jason.
- [ ] Centraliser la requête dans `Amanogawa.Atlas.EventQueries` (module de requêtes du contexte, fragments PostGIS uniquement ici) :
  - filtre spatial : `ST_Intersects(geom, ST_MakeEnvelope(...4326))`, avec `OR` entre les deux enveloppes en cas d'antiméridien ;
  - filtre temporel par chevauchement d'intervalles sur les années : `begin_year <= to AND coalesce(end_year, begin_year) >= from` (comparaison sur les années seulement, conformément à la règle géo-temporelle) ;
  - tri `sitelink_count` desc, départage déterministe par `qid` asc ;
  - `LIMIT` serveur ;
  - exclusion des événements sans géométrie.
- [ ] Construire les features avec propriétés minimales : `qid`, `label` (fr avec repli en), `year` (`begin_year`), `precision` (`begin_precision`), `importance` (`sitelink_count`). Géométrie : Point converti via `Geo.JSON.encode!/1` au bord web.
- [ ] Migration : index composites au service de la requête critique, dimensionnés par la mesure (candidats : btree `(begin_year, sitelink_count DESC)`, btree partiel `sitelink_count DESC WHERE geom IS NOT NULL`, en complément du GiST existant sur `geom`). Ne garder que les index justifiés par les plans mesurés.
- [ ] Exécuter `EXPLAIN (ANALYZE, BUFFERS)` sur le corpus complet pour au moins trois scénarios : monde entier + plage complète, bbox continentale + fenêtre large, bbox zoomée + fenêtre étroite. Vérifier la cible < 300 ms p95. Consigner les plans retenus et les mesures dans la moduledoc de `Amanogawa.Atlas.EventQueries` et dans `.claude/memory/` (leçon apprise).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `EventsQuery` parse `bbox=2.0,48.0,3.0,49.0&from=-500&to=500&limit=100` et produit les options normalisées attendues.
- [ ] **Edge case** : bbox traversant l'antiméridien (`170,-10,-170,10`) décomposée en deux enveloppes correctes ; bbox absente : monde entier ; `from`/`to` absents : plage complète.
- [ ] **Error case** : bbox à 3 composantes, latitude hors [-90, 90], `from > to`, année sous -13_800_000_000, année au-dessus de l'année courante, `limit` non entier : chaque cas produit une erreur de validation ciblée.
- [ ] **Limit case** : `limit=2000` accepté, `limit=2001` tronqué à 2000, `limit=0` rejeté ; bornes exactes `from=-13800000000` et `to=` année courante acceptées.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute bbox valide générée (y compris antiméridien) et toute fenêtre valide, chaque feature retournée par `list_events_geojson/1` a sa géométrie dans la bbox, son intervalle d'années chevauchant la fenêtre, et le nombre de features est <= limit.
- [ ] **Property** (StreamData) : le tri par `importance` desc est un invariant de toute réponse (liste des `importance` décroissante).

### Doctests (si applicable)

- [ ] **Doctest** : parsing d'une bbox nominale et d'une bbox antiméridien dans le module de parsing (fonction pure).

### Tests d'intégration

- [ ] **Intégration** (DataCase, PostGIS réel) : événements insérés de part et d'autre de l'antiméridien retrouvés par une bbox qui le traverse ; événement hors bbox exclu ; événement sans `geom` exclu ; repli du label en quand fr absent ; propriétés du GeoJSON limitées à `qid`, `label`, `year`, `precision`, `importance`.
- [ ] **Intégration** (ConnCase) : `GET /api/events` valide retourne 200, `content-type` JSON, structure `FeatureCollection` ; paramètres invalides retournent 400 avec erreurs structurées ; dépassement du quota Hammer retourne 429.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable ici, le parcours complet carte + endpoint est couvert par l'issue #015.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa_web/router.ex` (route `/api/events`)
  - `lib/amanogawa_web/controllers/api/event_controller.ex`
  - `lib/amanogawa_web/params/events_query.ex`
  - `lib/amanogawa_web/plugs/rate_limit.ex`
  - `lib/amanogawa/atlas.ex` (fonction publique `list_events_geojson/1`)
  - `lib/amanogawa/atlas/event_queries.ex`
  - `priv/repo/migrations/XXXX_add_events_query_indexes.exs`
  - `mix.exs`, `config/config.exs`, `config/runtime.exs` (Hammer)
  - Tests miroirs sous `test/amanogawa_web/` et `test/amanogawa/atlas/`
- **Documentation de référence** : ADR 0005 (hooks et endpoints dédiés), ADR 0007 (diffusion GeoJSON bornée), ADR 0006 (modèle temporel), `.claude/rules/security.md` (validation et rate limiting), `.claude/rules/geo-temporal.md` (fragments PostGIS centralisés, tri temporel), `.claude/memory/domain-model.md` (requête clé).
- **Compétences requises** : Ecto (fragments PostGIS, changesets schemaless), PostGIS (`ST_Intersects`, `ST_MakeEnvelope`, lecture de plans `EXPLAIN`), Phoenix (contrôleurs JSON, plugs), Hammer.
- **Points d'attention** :
  - SRID 4326 partout ; `ST_MakeEnvelope(..., 4326)` explicite.
  - L'antiméridien est le piège principal : jamais d'enveloppe unique quand `min_lon > max_lon`.
  - Le contexte Atlas est le seul à toucher `Repo` ; le contrôleur ne contient aucune logique de requête.
  - Endpoint strictement read-only et sans effet de bord (phase 1).
  - Les mesures `EXPLAIN ANALYZE` se font sur le corpus complet importé par #010, pas sur un jeu de données jouet ; si le p95 dépasse 300 ms, itérer sur les index dans cette même issue.
  - Pas de tirets cadratins ni de mention d'outillage dans le code et les commits.
