# Issue #017 -- Lignes de relations entre événements

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #016 (hover card et fiche événement), #011 (import des relations entre événements)

---

## Contexte

Les relations typées entre événements (`part_of`, `follows`, `cause`, `effect`, `significant`) sont en base depuis #011 mais invisibles. Cette issue les matérialise sur la carte : quand un événement est sélectionné (mécanique posée en #016, événements `event_selected` / `event_deselected` poussés par la LiveView au hook), le hook récupère ses relations via un nouvel endpoint `GET /api/events/:qid/links` et trace des lignes vers les événements liés, colorées par type de relation, avec une animation d'apparition. À la désélection, tout est nettoyé.

Architecture identique à #014 : contrôleur mince, requête centralisée dans le module de requêtes d'Atlas, GeoJSON au bord web, endpoint read-only rate limité. Les lignes sont des `LineString` GeoJSON dans une source MapLibre dédiée (`event-links`), séparée de la source `events` pour permettre un cycle de vie indépendant (remplissage à la sélection, vidage à la désélection).

Choix de tracé : segments droits (`LineString` à deux points) pour le MVP. L'arc de grand cercle densifié (mentionné dans la vue d'ensemble comme optionnel) est différé : à n'introduire que si le rendu des liaisons longue distance le justifie visuellement, dans une issue ultérieure.

## User Story

> En tant que visiteur ayant sélectionné un événement, je veux voir des lignes le reliant aux événements associés (causes, conséquences, épisodes d'un même ensemble), afin de percevoir d'un coup d'œil le réseau historique autour de cet événement.

---

## Tâches

- [ ] Ajouter `Amanogawa.Atlas.list_event_links_geojson/1` à l'API publique : reçoit un QID ; retourne `{:error, :not_found}` si l'événement est inconnu, sinon `{:ok, feature_collection}` avec une feature `LineString` par relation dont les deux extrémités ont une géométrie.
- [ ] Requête dans `Amanogawa.Atlas.EventQueries` : relations où l'événement est source OU cible, jointure sur les deux événements, exclusion des extrémités sans `geom` ; propriétés par feature : `link_type`, `direction` (`:outgoing` | `:incoming`), `target_qid`, `target_label` (fr, repli en), `target_year` ; coordonnées ordonnées de l'événement sélectionné vers l'événement lié.
- [ ] Ajouter la route `GET /api/events/:qid/links` et l'action `links` au contrôleur API events : validation du format QID (`^Q\d+$`, comme #016) avant tout accès base, 400 si invalide, 404 si inconnu, 200 avec FeatureCollection sinon (vide si aucune relation tracée) ; rate limiting du pipeline `:api` déjà en place.
- [ ] Créer `assets/js/map/link_layers.js` : définition de la source `event-links` (FeatureCollection vide) et du layer `event-links-lines` (type `line`) ; `line-color` par expression `match` sur `["get", "link_type"]` avec une couleur par type issue des design tokens (#004), largeur légèrement supérieure pour `cause`/`effect` ; layer inséré sous les layers d'événements pour ne pas masquer les marqueurs.
- [ ] Dans `MapHook`, consommer les événements poussés par la LiveView (#016) :
  - `event_selected` : fetch `/api/events/:qid/links` avec AbortController (annulation si nouvelle sélection rapide), `setData` sur la source `event-links` ;
  - `event_deselected` : `abort()` du fetch en cours et `setData` FeatureCollection vide.
- [ ] Animation d'apparition : transition de peinture sur `line-opacity` (0 vers 1) après `setData` ; désactivée si `prefers-reduced-motion` (même mécanique que #015, réutiliser l'utilitaire existant).
- [ ] Nettoyage dans `destroyed()` : abort du fetch de liens, en complément du nettoyage existant.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** (DataCase) : événement avec relations sortantes et entrantes : une feature par relation, `direction` correcte, coordonnées ordonnées du sélectionné vers le lié, `link_type` fidèle.
- [ ] **Edge case** (DataCase) : relation dont la cible n'a pas de géométrie : exclue sans erreur ; événement sans aucune relation : FeatureCollection vide ; libellé cible en repli en.
- [ ] **Error case** (DataCase) : QID inconnu retourne `{:error, :not_found}`.
- [ ] **Limit case** : événement fortement connecté (des dizaines de relations) : toutes les features présentes, réponse bien formée ; deux extrémités confondues (même point) : LineString dégénérée exclue ou tolérée, comportement choisi documenté et testé.
- [ ] **Happy path** (node:test sur `link_layers.js`) : l'expression `match` couvre les cinq types de relation plus une couleur par défaut ; la variante `reducedMotion` ne contient pas de transition.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout ensemble de relations généré, chaque feature retournée a exactement deux positions, des coordonnées dans les bornes monde, et un `link_type` appartenant à l'énumération des types.

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (pas de nouvelle fonction pure documentable isolément ; la validation de QID est couverte en #016).

### Tests d'intégration

- [ ] **Intégration** (ConnCase) : `GET /api/events/:qid/links` sur un événement avec relations retourne 200 et la FeatureCollection attendue ; QID invalide 400 ; QID inconnu 404 ; événement sans relations 200 avec collection vide.

### Tests end-to-end (si applicable)

- [ ] **E2E** : sélectionner un événement possédant des relations : vérifier via JavaScript que la source `event-links` contient des features ; désélectionner : vérifier que la source est vide.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/atlas.ex` (fonction `list_event_links_geojson/1`)
  - `lib/amanogawa/atlas/event_queries.ex` (requête des relations)
  - `lib/amanogawa_web/controllers/api/event_controller.ex` (action `links`), `lib/amanogawa_web/router.ex` (route)
  - `assets/js/hooks/map.js`, `assets/js/map/link_layers.js` (+ test node:test)
  - Tests miroirs sous `test/`
- **Documentation de référence** : ADR 0005 et 0007, `.claude/memory/domain-model.md` (EventLink : types, unicité source/cible/type), `.claude/rules/security.md` (validation d'id, endpoints read-only), issue #016 (contrat `event_selected` / `event_deselected`).
- **Compétences requises** : Ecto (jointures, requêtes bidirectionnelles), MapLibre (layers line, expressions `match`, ordre des layers), JavaScript vanilla.
- **Points d'attention** :
  - Une ligne traversant l'antiméridien sera tracée « par le long chemin » avec des segments droits : limitation MVP assumée, à documenter dans le code ; ne pas tenter de correction partielle non testée.
  - La source `event-links` reste dédiée : ne jamais mélanger lignes et points dans la même source.
  - Réutiliser l'utilitaire `prefers-reduced-motion` et l'AbortController introduits en #015, ne pas dupliquer.
  - Sélections rapides successives : le fetch précédent doit être annulé avant le nouveau, sinon une réponse lente peut afficher les liens d'un autre événement.
  - Endpoint strictement read-only, aucune écriture ni effet de bord.
  - Pas de tirets cadratins ni de mention d'outillage dans le code et les commits.
