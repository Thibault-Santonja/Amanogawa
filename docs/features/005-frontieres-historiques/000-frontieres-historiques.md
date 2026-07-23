# F05 -- Frontières historiques

> Phase 1 | Priorité P1 | Estimation : 1.5 semaines

## Résumé

Afficher les zones d'influence des entités politiques selon la période sélectionnée : import des polygones datés Cliopatria (CC BY 4.0, -3400 à 2024) et historical-basemaps (GPL-3.0, préhistoire), simplification à l'import, endpoint par année, rendu en aplats semi-transparents assumant l'imprécision des frontières anciennes. L'année de référence affichée est la borne haute de la fenêtre temporelle (choix simple et lisible, ajustable ensuite).

Fondé sur l'ADR 0004 (sources et licences) et 0007 (diffusion bornée).

## Analyse

### Architecture

- Schémas `atlas.polities` (nom, période) et `atlas.borders` (polity_id, geom MultiPolygon 4326, from_year, to_year, source, precision) ; GiST + index (from_year, to_year).
- Import par mix task : téléchargement manuel documenté (fichiers volumineux, ~307 Mo pour Cliopatria), lecture GeoJSON en streaming, validation géométries (ST_MakeValid), simplification par niveaux (ST_SimplifyPreserveTopology) pour tenir un payload raisonnable par année.
- Jonction -3400 : historical-basemaps sert les années < -3400 uniquement (pas de fusion des deux sources sur une même année).
- `GET /api/borders?year=` : polygones actifs (`from_year <= year AND to_year >= year`), GeoJSON, couleur stable par polity (hash du nom -> teinte), rate limité.
- `MapHook` : source + layer fill sous les événements, opacité ~0.25, bordures floues (pas de trait dur), labels des grandes entités à fort zoom, transition d'opacité au changement d'année.

### Éthique / Crédits

- Attribution Cliopatria et historical-basemaps dans les crédits carte et la page Sources (F06 #027).
- Mention visible du caractère approximatif ("zones d'influence, approximatives par nature").

### Performance

- Payload visé < 1.5 Mo gzip par année au niveau de simplification par défaut ; mesuré et documenté dans l'issue #025.
- Cache HTTP possible (les frontières d'une année sont immuables entre deux imports).

## User Stories

- GIVEN une fenêtre finissant en 1200, WHEN la carte s'affiche, THEN je vois les zones d'influence de 1200 en aplats discrets sous les événements, avec crédits des sources.
- GIVEN un déplacement de la fenêtre vers -50, WHEN la carte se met à jour, THEN les frontières changent avec une transition douce.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #023 Schémas Polity/Border + import Cliopatria | 001-import-cliopatria.md | 16h |
| #024 Import historical-basemaps (préhistoire) | 002-import-historical-basemaps.md | 8h |
| #025 Endpoint borders + rendu MapLibre | 003-endpoint-rendu-frontieres.md | 12h |

## Dépendances

- Prérequis : F01 (#001), F02 (#007 pour les patterns), F03 (#014 pour les gabarits de validation et le rate limiting, #015).
- Sortie : critère de sortie du MVP.
