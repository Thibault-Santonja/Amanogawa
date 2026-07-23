# 0005. Rendre la carte avec MapLibre GL JS et la frise avec d3, en hooks LiveView vanilla

Date : 2026-07-23
Statut : Accepté

## Contexte

Le front doit afficher potentiellement des dizaines de milliers d'événements (corpus ~420 000, filtré par fenêtre temporelle et viewport), des polygones de frontières, des lignes de relations, avec des animations fluides (drag de fenêtre temporelle, gradient de couleur, hover). Contraintes : pas de framework front JS/TS, Tailwind, LiveView au centre. Le prototype 2020-2022 utilisait React-Leaflet : Leaflet manipule des marqueurs DOM et atteint ses limites en volume et en animation.

## Décision

Nous allons :
- confier l'état applicatif (fenêtre temporelle, filtres, sélection) à LiveView ;
- rendre la carte avec MapLibre GL JS (WebGL, open source, sans clé) dans un hook JS vanilla `MapHook`, en sources GeoJSON stylées par expressions (gradient temporel, transparence des frontières) ;
- rendre la frise avec d3 (modules scale/zoom/selection uniquement) dans un hook `TimelineHook`, avec échelle symlog ;
- faire transiter les gros volumes (GeoJSON événements, frontières) par des endpoints JSON dédiés appelés par les hooks, LiveView n'échangeant que des intentions et bornes légères ;
- vendorer MapLibre et d3 via le pipeline d'assets (pas de CDN, CSP stricte) ;
- utiliser un fond de tuiles vectorielles neutre et respectueux (OpenFreeMap ou Protomaps/PMTiles, tranché en issue d'infrastructure).

## Conséquences

Positives :
- WebGL absorbe les volumes et offre les animations demandées (easing natif MapLibre, expressions de style pilotées par données).
- Pas de framework front : les hooks restent du JS vanilla ciblé, testables et remplaçables.
- La séparation "état via LiveView, volumes via endpoints JSON" évite de saturer le canal WebSocket de diffs énormes.

Négatives :
- MapLibre est plus complexe que Leaflet (styles, sources, layers) ; accepté, la complexité est localisée dans un hook.
- d3 introduit une dépendance JS supplémentaire ; acceptée car limitée aux modules d'échelle et la frise custom le justifie.

## Alternatives considérées

**Leaflet.** Simple et connu (prototype 2020-2022), mais marqueurs DOM inadaptés aux volumes et animations visés ; rejeté.

**SVG/Canvas maison pour la carte.** Contrôle total mais réinvention d'un moteur cartographique (projections, tuiles, interactions) ; rejeté.

**Frise 100 % maison sans d3.** Possible, mais les échelles symlog, le zoom et le brush de d3 sont exactement le besoin ; réécrire ces primitives serait de la complexité gratuite.
