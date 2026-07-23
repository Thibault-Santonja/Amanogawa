# F03 -- Carte interactive

> Phase 1 | Priorité P0 | Estimation : 2 semaines

## Résumé

Afficher les événements sur la carte MapLibre : endpoint GeoJSON borné (bbox + fenêtre temporelle + importance), marqueurs stylés par données, bulle de survol avec le résumé Wikipedia (attribution CC BY-SA), fiche événement avec bouton vers l'article, et lignes tracées vers les événements liés quand un événement est sélectionné. La LiveView `Explore` orchestre l'état (fenêtre, sélection, filtres) et le synchronise dans l'URL (liens partageables).

Fondé sur les ADR 0005 (hooks) et 0007 (diffusion GeoJSON bornée).

## Analyse

### Architecture

- `GET /api/events?bbox=&from=&to=&limit=` : contrôleur Phoenix mince -> `Amanogawa.Atlas.list_events_geojson/1` ; validation stricte des paramètres (années bornées, bbox monde, limit plafonné), tri par `sitelink_count` desc.
- `MapHook` (assets/js/hooks/map.js) : source GeoJSON `events`, layers circle + symbol, expressions de style (taille par importance, couleur par âge via tokens partagés en F04), `queryRenderedFeatures` pour hover/sélection.
- Hover card : composant HTML positionné par le hook, contenu (titre, résumé tronqué, vignette, mention CC BY-SA) fourni par un endpoint léger `GET /api/events/:qid/summary` ou embarqué dans les propriétés GeoJSON (à trancher dans l'issue selon poids du payload).
- Fiche événement : panneau latéral LiveView (sélection poussée par le hook via `pushEvent`), bouton externe vers Wikipedia (`rel="noopener noreferrer"`).
- Relations : `GET /api/events/:qid/links` -> lignes `LineString` (grand cercle si visuel pertinent) dans une source dédiée, colorées par type de relation.

### Sécurité

- Endpoints read-only, rate limités (Hammer), paramètres validés et bornés (IDOR sans objet en phase 1, données publiques, mais gabarits de validation posés pour la phase 2).
- Échappement systématique des contenus Wikipedia affichés (extract text, pas extract_html, ou sanitization stricte si HTML retenu).

### Performance

- La requête critique (bbox + fenêtre + importance) doit tenir < 300 ms p95 sur le corpus complet : index composites et EXPLAIN documentés dans l'issue #014.
- Debounce des moveend/zoom côté hook ; annulation des fetch obsolètes (AbortController).

### UX / Animations

- Fade-in des marqueurs, transitions d'opacité au changement de fenêtre, hover card avec micro-délai (150 ms) pour éviter le clignotement ; `prefers-reduced-motion` respecté.

## User Stories

- GIVEN la carte chargée, WHEN je survole un marqueur, THEN une bulle affiche titre et résumé avec attribution, sans appel Wikipedia côté client.
- GIVEN un événement sélectionné, WHEN la fiche s'ouvre, THEN je peux ouvrir l'article Wikipedia dans un nouvel onglet et voir les lignes vers les événements liés.
- GIVEN une URL partagée (fenêtre + sélection), WHEN je l'ouvre, THEN je retrouve exactement la même vue.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #014 Endpoint events GeoJSON borné + requête critique | 001-endpoint-events-geojson.md | 12h |
| #015 MapHook : affichage des événements | 002-maphook-affichage-evenements.md | 12h |
| #016 Hover card + fiche événement + lien Wikipedia | 003-hover-card-fiche-evenement.md | 12h |
| #017 Lignes de relations entre événements | 004-lignes-relations.md | 8h |
| #018 LiveView Explore : état, URL partageable | 005-liveview-explore.md | 12h |

## Dépendances

- Prérequis : F01 (#005), F02 (#007, #010, #012).
- Sortie : F04 (la frise pilote la fenêtre affichée par la carte).
