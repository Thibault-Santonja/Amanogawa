# Issue #025 -- Endpoint borders et rendu MapLibre

**Feature :** F05 -- Frontières historiques
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #023, #015

---

## Contexte

Les polygones datés sont en base (#023, complétés par #024 quand elle est faite). Cette issue les rend visibles : un endpoint read-only `GET /api/borders?year=` conforme à l'ADR 0007 (validation stricte, bornage serveur, rate limiting, endpoint pur et cacheable) et le rendu dans le `MapHook` MapLibre (#015) en aplats semi-transparents sous les événements, assumant l'imprécision des frontières historiques (ADR 0004).

Le problème résolu : servir pour une année donnée les polygones actifs (`from_year <= year <= to_year`) en GeoJSON simplifié, avec une couleur stable par entité politique (hash du nom vers une teinte HSL, identique d'une année à l'autre pour que l'oeil suive une entité dans le temps), puis les afficher sans trait dur, avec labels des grandes entités à fort zoom et transition douce au changement d'année. L'année de référence est la borne haute de la fenêtre temporelle pilotée par la frise (choix F05, simple et lisible).

Insertion dans l'architecture : contrôleur API mince dans la couche web, logique de requête et sérialisation GeoJSON derrière la façade `Amanogawa.Atlas` (GeoJSON à la bordure uniquement), rendu dans `assets/js/hooks/map.js` selon les patterns posés par F03 (debounce, AbortController, sources et layers MapLibre).

Impact sur le reste du système : les crédits Cliopatria et historical-basemaps deviennent visibles sur la carte (obligation CC BY 4.0 et GPL-3.0, repris en détail par la page Sources F06 #027) ; le budget payload mesuré ici peut renvoyer vers #023 pour recalibrer les tolérances de simplification.

## User Story

> En tant que visiteur, je veux voir les zones d'influence des entités politiques de l'année affichée, en aplats discrets sous les événements, afin de situer les événements dans leur contexte politique, avec une transition douce quand je déplace la fenêtre temporelle.

---

## Tâches

- [ ] Route `GET /api/borders` dans le router (pipeline API read-only) et contrôleur mince déléguant à `Amanogawa.Atlas.list_borders_geojson/1`.
- [ ] Validation stricte du paramètre `year` : entier requis, sinon 400 avec erreur JSON ; valeur bornée côté serveur (clamp aux bornes des données, -123000 à 2024, documenté dans le contrôleur).
- [ ] Requête dans le module de requêtes Atlas : polygones actifs (`from_year <= year AND to_year >= year`), géométrie du niveau de simplification par défaut (`geom_medium` de #023), `ST_AsGeoJSON` en base, jointure polities.
- [ ] FeatureCollection GeoJSON avec properties par feature : `name`, `source`, `precision`, `color`, `area_km2` (aire calculée en base, sert au filtrage des labels côté client).
- [ ] Couleur stable par polity : fonction pure serveur, hash du nom vers une teinte HSL (S et L fixes, par exemple `hsl(h, 45%, 55%)`, teinte dans [0, 360)), injectée dans `properties.color` ; même nom, même couleur, quelle que soit l'année.
- [ ] Rate limiting Hammer sur l'endpoint, même gabarit que `/api/events` (#014).
- [ ] Cache HTTP : ETag fort dérivé de `(year, horodatage du dernier import de frontières)`, gestion de `If-None-Match` avec réponse 304, `Cache-Control: public, max-age` raisonnable (les frontières d'une année sont immuables entre deux imports).
- [ ] `MapHook` : source GeoJSON `borders` et layer `fill` inséré sous les layers d'événements (`beforeId`), `fill-opacity` ~0.25, aucun layer `line` (pas de trait dur : frontières floues assumées, mention "zones d'influence, approximatives par nature" reprise dans l'UI ou les crédits).
- [ ] Labels : layer `symbol` sur le nom des grandes entités uniquement (filtre sur `area_km2`), visible à fort zoom (`minzoom` à calibrer), collisions gérées par MapLibre.
- [ ] Chargement piloté par la fenêtre temporelle : le hook écoute le même événement de fenêtre que les événements (F03/F04), année de référence = borne haute de la fenêtre ; fetch uniquement quand l'année de référence change, debounce et AbortController pour annuler les requêtes obsolètes.
- [ ] Transition douce au changement d'année : fondu d'opacité (`fill-opacity-transition`) lors du remplacement des données ; respecter `prefers-reduced-motion` (remplacement sec dans ce cas).
- [ ] Crédits visibles sur la carte : ajouter "Cliopatria (CC BY 4.0)" et "historical-basemaps (GPL-3.0)" au contrôle d'attribution MapLibre, avec liens vers les sources.
- [ ] Mesurer le payload : tailles gzip de la réponse pour des années représentatives (-5000, -2500, -50, 800, 1200, 1500, 1900, 2000), consignées dans cette issue et dans `.claude/memory/` ; cible < 1.5 Mo gzip par année au niveau par défaut. Si dépassement, recalibrer les tolérances de simplification (#023) et re-mesurer.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : la fonction couleur retourne une chaîne HSL valide pour un nom donné, identique à chaque appel.
- [ ] **Edge case** : noms unicode (accents, idéogrammes), noms très longs, noms d'un seul caractère produisent tous une couleur valide ; deux noms distincts courants produisent des teintes distinctes (cas fixés).
- [ ] **Error case** : `year` absent, non entier ou vide donne une réponse 400 avec message d'erreur JSON (test du plug/contrôleur de validation).
- [ ] **Limit case** : `year` au-delà des bornes est clampé (-123000 et 2024) ; comportement documenté et testé.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute chaîne binaire valide en nom, la teinte est dans [0, 360) et la fonction est déterministe (deux appels, même résultat).

### Doctests (si applicable)

- [ ] **Doctest** : fonction couleur (exemple nominal dans le `@moduledoc`, nom connu vers sa couleur HSL).

### Tests d'intégration

- [ ] **Intégration** (DataCase, PostGIS réel) : `list_borders_geojson/1` retourne uniquement les polygones actifs ; bornes inclusives vérifiées (`year == from_year` et `year == to_year` inclus, `year == to_year + 1` exclu) ; FeatureCollection bien formée avec toutes les properties (`name`, `source`, `precision`, `color`, `area_km2`).
- [ ] **Intégration** (ConnCase) : 200 avec `content-type` JSON et en-tête ETag présent ; requête avec `If-None-Match` correspondant renvoie 304 sans corps ; dépassement du rate limit renvoie 429 ; paramètre invalide renvoie 400.
- [ ] **Intégration** (ConnCase) : la réponse pour une année sans données (fixture vide) est une FeatureCollection vide, 200.

### Tests end-to-end (si applicable)

- [ ] **E2E** (PhoenixTest ou Wallaby, parcours critique) : charger la carte, vérifier la présence des crédits Cliopatria et historical-basemaps dans l'attribution, déplacer la fenêtre temporelle et vérifier que la couche de frontières se met à jour (au minimum : l'appel `/api/borders` avec la nouvelle année de référence est émis et la source MapLibre est remplacée).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa_web/router.ex` (route, à compléter)
  - `lib/amanogawa_web/controllers/api/border_controller.ex` (nouveau), plug ou helper de validation partagé avec `/api/events` (#014) : chercher l'existant avant de créer
  - `lib/amanogawa/atlas.ex` (façade : `list_borders_geojson/1`, à compléter)
  - module de requêtes borders du contexte Atlas (créé en #023, à compléter : requête active, `ST_AsGeoJSON`, aire)
  - `lib/amanogawa/atlas/polity_color.ex` (nouveau, fonction pure de couleur)
  - `assets/js/hooks/map.js` (source, layers, transitions, crédits, à compléter)
  - `test/amanogawa_web/controllers/api/border_controller_test.exs`, `test/amanogawa/atlas/polity_color_test.exs`, `test/amanogawa/atlas_test.exs` (compléter), test E2E dans l'arborescence posée par F03
- **Documentation de référence** : ADR 0004 (imprécision assumée, attributions), ADR 0005 (répartition LiveView/hooks), ADR 0007 (endpoints bornés, rate limiting, cache), F03 issues #014 et #015 (gabarits validation, Hammer, debounce, AbortController), F05 overview (année de référence = borne haute), `.claude/memory/data-sources.md`.
- **Compétences requises** : Phoenix (contrôleurs API, plugs, en-têtes de cache HTTP), PostGIS (`ST_AsGeoJSON`, aire sur geography), MapLibre GL JS (sources GeoJSON, ordre des layers, expressions de style, transitions), notions de cache HTTP (ETag, 304).
- **Points d'attention** :
  - GeoJSON à la bordure uniquement : la sérialisation se fait dans le module de requêtes Atlas via `ST_AsGeoJSON`, jamais dans le contrôleur ni côté client.
  - La couleur est calculée côté serveur et lue par le style MapLibre (`["get", "color"]`) : ne pas dupliquer le hash côté JS.
  - Ordre des layers : les frontières se placent sous les layers d'événements (utiliser `beforeId` à l'ajout) ; vérifier après tout rechargement de style.
  - Pas de trait dur : aucun layer `line` ; l'aplat semi-transparent suffit, la superposition de deux entités reste lisible par différence de teinte.
  - ETag invalidé par un nouvel import : dériver l'horodatage du dernier import via la façade Atlas (max des `updated_at` ou table de méta d'import), pas de valeur codée en dur.
  - Endpoint sans effet de bord, read-only ; aucune donnée personnelle, zéro tracking.
  - Si le payload dépasse 1.5 Mo gzip pour les années denses, la correction se fait dans les tolérances de #023 (et non en filtrant silencieusement des entités) ; documenter toute décision.
