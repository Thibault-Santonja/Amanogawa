# Issue #015 -- MapHook : affichage des événements

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #005 (fond de carte + MapHook minimal), #014 (endpoint events GeoJSON)

---

## Contexte

Le `MapHook` créé en #005 affiche un fond de carte vide. Cette issue le fait vivre : il consomme `GET /api/events` (issue #014) et affiche les événements en source GeoJSON MapLibre, stylée par expressions pilotées par les données (ADR 0005).

Principes d'architecture à respecter : LiveView orchestre l'état (fenêtre temporelle, filtres), le hook possède le rendu et va chercher lui-même les gros volumes par fetch sur l'endpoint JSON (jamais par diffs LiveView). Le hook expose donc une interface d'événements (`set_time_window` entrant) qui sera pilotée par la LiveView Explore (#018) puis par la frise (F04).

Côté rendu : deux layers (circle pour les marqueurs, symbol pour les libellés), taille des cercles proportionnelle à l'importance (`sitelink_count`), visibilité des libellés dépendante du zoom pour éviter la bouillie visuelle à faible zoom. Les rechargements sont déclenchés par les déplacements et zooms de carte, avec debounce et annulation des requêtes obsolètes (AbortController). Les apparitions de marqueurs sont animées (fade-in), en respectant `prefers-reduced-motion`.

## User Story

> En tant que visiteur, je veux voir les événements historiques apparaître sur la carte au fil de mes déplacements et zooms, les plus importants en premier et bien lisibles, afin d'explorer une région ou une période sans manipulation supplémentaire.

---

## Tâches

- [ ] Extraire les fonctions pures du hook dans des modules testables :
  - `assets/js/map/bbox.js` : conversion `map.getBounds()` vers le paramètre `bbox` de l'API, avec normalisation des longitudes hors [-180, 180] (MapLibre peut retourner des bounds au-delà après un tour du monde) et bascule au format antiméridien (`min_lon > max_lon`) quand la vue traverse la ligne de changement de date.
  - `assets/js/map/debounce.js` : debounce générique (≈250 ms) réutilisable.
  - `assets/js/map/event_layers.js` : constantes et fabriques des définitions de layers et d'expressions de style (testables sans MapLibre).
- [ ] Dans `assets/js/hooks/map.js`, au `load` de la carte : ajouter la source GeoJSON `events` (FeatureCollection vide), puis les layers :
  - `events-circles` (type `circle`) : `circle-radius` par interpolation sur `["get", "importance"]` combinée au zoom (petits points à faible zoom, cercles francs à fort zoom) ; couleurs issues des design tokens (#004), pas de valeurs hexadécimales en dur si un token existe ;
  - `events-labels` (type `symbol`) : `text-field` sur `["get", "label"]`, visible seulement à partir d'un seuil de zoom via `minzoom` et un `step` sur l'importance (les événements majeurs sont libellés plus tôt), gestion des collisions laissée à MapLibre.
- [ ] Implémenter `fetchEvents()` : construit l'URL `/api/events` avec `bbox` (module bbox), `from`/`to` (fenêtre courante du hook), `limit` ; `AbortController` : toute nouvelle requête annule la précédente ; en réponse, `setData` sur la source `events` ; les erreurs réseau et les `AbortError` sont silencieuses côté utilisateur (log console en dev), la carte garde les données précédentes.
- [ ] Brancher `fetchEvents` (debouncé) sur les événements MapLibre `moveend` et `zoomend` ; premier chargement au `load` de la carte.
- [ ] Gérer l'événement serveur `set_time_window` (`handleEvent`) : mise à jour de `{from, to}` dans l'état du hook puis refetch ; valeurs par défaut (plage complète) tant que la LiveView n'a rien poussé.
- [ ] Fade-in des marqueurs : transition de peinture MapLibre sur `circle-opacity` (et `text-opacity`), opacité initiale montée après `setData` ; si `matchMedia("(prefers-reduced-motion: reduce)")` est vrai, désactiver toutes les transitions (apparition immédiate).
- [ ] `destroyed()` : annuler le timer de debounce, `abort()` du fetch en cours, retirer les listeners `moveend`/`zoomend`, puis le nettoyage carte déjà en place depuis #005.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** (node:test sur `assets/js/map/bbox.js`) : bounds nominaux convertis en `min_lon,min_lat,max_lon,max_lat` correct.
- [ ] **Edge case** : bounds traversant l'antiméridien produisant `min_lon > max_lon` ; bounds avec longitudes hors [-180, 180] normalisées ; vue monde entière plafonnée aux bornes valides.
- [ ] **Error case** : bounds dégénérés (largeur nulle) gérés sans exception.
- [ ] **Limit case** (node:test sur `debounce.js`) : appels rapprochés fusionnés en un seul, dernier argument gagnant ; annulation effective.
- [ ] **Happy path** (node:test sur `event_layers.js`) : les définitions de layers contiennent les expressions attendues (interpolation sur `importance`, `minzoom` des libellés) ; la variante `reducedMotion` ne contient aucune transition.

### Property-based tests (si applicable)

- [ ] **Property** : non applicable côté Elixir (aucun code serveur dans cette issue) ; les invariants du paramètre bbox sont couverts par les tests node:test ci-dessus.

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (pas de module Elixir créé).

### Tests d'intégration

- [ ] **Intégration** : non applicable côté serveur ; l'endpoint est couvert par #014.

### Tests end-to-end (si applicable)

- [ ] **E2E** (Wallaby ou PhoenixTest) : charger la page carte, attendre le chargement, vérifier via JavaScript exécuté dans la page que la source `events` contient des features (`querySourceFeatures`) et qu'aucune erreur JS n'est levée ; déplacer la carte et vérifier qu'un nouveau contenu est chargé.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/js/hooks/map.js` (extension du hook de #005)
  - `assets/js/map/bbox.js`, `assets/js/map/debounce.js`, `assets/js/map/event_layers.js` (nouveaux)
  - `assets/js/map/*.test.js` (node:test, exécutés via `node --test assets/js`, script npm à ajouter dans `assets/package.json` et au précommit si simple)
  - Test E2E sous `test/` selon l'outillage retenu par le projet
- **Documentation de référence** : ADR 0005 (hooks vanilla, volumes par endpoints), ADR 0007 (bornage serveur), `.claude/rules/liveview.md` (hooks : debounce, cleanup, payloads), documentation MapLibre (sources GeoJSON, expressions, transitions de peinture).
- **Compétences requises** : MapLibre GL JS (sources, layers, expressions `interpolate`/`step`, transitions), JavaScript vanilla (AbortController, matchMedia), hooks LiveView (`handleEvent`, `destroyed`).
- **Points d'attention** :
  - JS vanilla uniquement, aucun framework ni dépendance front supplémentaire ; node:test est fourni par Node, aucun runner à installer.
  - Le hook ne stocke jamais la liste des événements en dehors de la source MapLibre (pas de duplication mémoire).
  - Les intentions client vers serveur (sélection, déplacement notifié) arrivent dans les issues #016 et #018 : ne pas pousser d'événements vers la LiveView ici, seulement consommer `set_time_window`.
  - L'AbortController est indispensable : sans lui, une réponse lente peut écraser une réponse plus récente (données obsolètes affichées).
  - `prefers-reduced-motion` se lit une fois au montage et via listener de changement, pas à chaque frame.
  - Pas de tirets cadratins ni de mention d'outillage dans le code et les commits.
