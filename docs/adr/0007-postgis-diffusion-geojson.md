# 0007. Stocker en PostGIS et diffuser en GeoJSON borné (bbox + fenêtre + importance)

Date : 2026-07-23
Statut : Accepté

## Contexte

Corpus visé : ~420 000 événements géolocalisés et ~14 000 polygones de frontières. Tout envoyer au client est exclu. Les besoins de requêtage sont spatiaux (viewport), temporels (fenêtre de frise) et de pertinence (montrer d'abord les événements importants à faible zoom). PostGIS fournit index GiST, `ST_Intersects`, `ST_MakeEnvelope`, simplification de géométries.

## Décision

Nous allons :
- stocker toutes les géométries en PostGIS, SRID 4326 (`geometry(Point,4326)` pour les événements, `geometry(MultiPolygon,4326)` pour les frontières), index GiST systématique ;
- servir les données par endpoints JSON dédiés, read-only, appelés par les hooks : `GET /api/events?bbox=&from=&to=&limit=` et `GET /api/borders?year=`, avec validation stricte et bornage serveur de tous les paramètres ;
- classer par importance (`sitelink_count` en proxy) et limiter côté serveur selon le zoom, plutôt que clusteriser d'abord (clustering MapLibre en secours si besoin) ;
- simplifier les polygones de frontières à l'import (ST_SimplifyPreserveTopology par niveaux) pour tenir le budget de payload ;
- rate-limiter ces endpoints (Hammer) et les garder sans effet de bord.

## Conséquences

Positives :
- La requête critique (bbox + fenêtre + importance) est un plan d'index simple et mesurable ; le payload reste borné quelle que soit la densité historique.
- Endpoints purs et cacheables (ETag/Cache-Control possibles ensuite).

Négatives :
- Un tri par importance masque des événements mineurs à faible zoom ; assumé, c'est un choix d'UX documenté (zoomer ou réduire la fenêtre les révèle).
- Deux canaux front (WebSocket LiveView + fetch JSON) ; accepté, chacun fait ce pour quoi il est bon (voir ADR 0005).

## Alternatives considérées

**Tuiles vectorielles générées (ST_AsMVT ou tileserver).** Optimal à très grande échelle, mais infrastructure supplémentaire prématurée pour le MVP ; reporté, l'interface des hooks le permettra plus tard sans refonte.

**Tout charger côté client une fois.** 420 000 points + polygones : payload et mémoire intenables ; rejeté.

**Diffs LiveView pour les données géo.** Saturerait le canal WebSocket et le DOM ; rejeté (ADR 0005).
