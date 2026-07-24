# Amanogawa (天の川) -- Roadmap Produit

> Document chapeau. Chaque feature est détaillée dans son dossier `docs/features/NNN-slug/`.

## Vision

Rendre l'histoire visible : une carte du monde et une frise chronologique interactives, de la préhistoire à aujourd'hui. Événements issus de Wikidata et Wikipedia, zones d'influence politiques en fond de carte, relations tracées entre événements. À terme, un éditeur collaboratif ouvert avec une algorithmie sociale éthique.

Principes fondateurs : zéro tracking, AGPL-3.0, auto-hébergeable, respect de l'étiquette Wikimedia, attribution des sources, honnêteté historiographique (précision des dates et flou des frontières assumés).

## Hypothèses de travail

| Paramètre | Valeur |
|-----------|--------|
| Équipe | 1 personne + agents |
| Stack | Phoenix 1.8 LiveView, PostgreSQL + PostGIS, Oban, MapLibre GL JS, d3, Tailwind v4 |
| Déploiement | Kamal 2, VPS Hetzner, Docker |
| Licence | AGPL-3.0, dépôt public |
| Corpus initial | ~420 000 événements Wikidata géolocalisables, ~14 000 polygones Cliopatria |
| MVP | Exploration carte + frise en lecture seule |

## Vue d'ensemble des phases

```
Phase 1 : MVP exploration (lecture seule)
  F01 fondations -> F02 ingestion -> F03 carte -> F04 frise -> F05 frontieres -> F06 deploiement

Phase 2 : collaboratif
  F07 comptes utilisateurs -> F08 editeur collaboratif
```

## Phase 1 -- MVP exploration

Objectif : un site public où l'on explore les événements historiques sur carte + frise, avec résumés, liens Wikipedia, relations et frontières historiques.

État au 2026-07-24 : les six features sont développées, revues (qualité + sécurité par feature, corrections appliquées) et mergées, couvertes par 856 tests dont une suite E2E navigateur de 12 scénarios. Restent à réaliser par l'opérateur : le déploiement réel (placeholders de `docs/ops/deploy.md`) et les imports de données réels (`docs/ops/sync.md`, mix tasks d'import des frontières), avec la mesure de payload et le recalibrage documentés à faire au premier import.

| ID | Feature | Priorité | Statut | Spec |
|----|---------|----------|--------|------|
| F01 | Fondations (projet, qualité, CI, fond de carte) | P0 | Livrée (PR #1) | [F01](features/001-fondations/000-fondations.md) |
| F02 | Ingestion Wikidata / Wikipedia | P0 | Livrée (PR #2) | [F02](features/002-ingestion-wikidata/000-ingestion-wikidata.md) |
| F03 | Carte interactive | P0 | Livrée (PR #3, E2E PR #5) | [F03](features/003-carte-interactive/000-carte-interactive.md) |
| F04 | Frise chronologique | P0 | Livrée (PR #4) | [F04](features/004-frise-chronologique/000-frise-chronologique.md) |
| F05 | Frontières historiques | P1 | Livrée (PR #6) | [F05](features/005-frontieres-historiques/000-frontieres-historiques.md) |
| F06 | Déploiement et pages légales | P1 | Livrée (PR #7) | [F06](features/006-deploiement/000-deploiement.md) |

Critère de sortie : parcours complet en production (charger la carte, régler la fenêtre temporelle, survoler un événement, ouvrir Wikipedia, voir les frontières de la période), >90% de couverture par module, precommit et CI verts.

## Phase 2 -- Collaboratif

Objectif : ouvrir la contribution, type wiki, avec une gouvernance transparente.

| ID | Feature | Priorité | Spec |
|----|---------|----------|------|
| F07 | Comptes utilisateurs (magic link) | P0 | [F07](features/007-comptes-utilisateurs/000-comptes-utilisateurs.md) |
| F08 | Éditeur collaboratif éthique | P0 | [F08](features/008-editeur-collaboratif/000-editeur-collaboratif.md) |

Critère de sortie : proposition d'édition, historique public des révisions, modération documentée.

## Dépendances entre features

```
F01 --+--> F02 --+--> F03 --> F04
      |          +--> F05
      +--> F06 (deployable des F03)
F07 --> F08 (phase 2, dependent de F01..F04)
```

## Risques et mitigations

| Risque | Impact | Probabilité | Mitigation |
|--------|--------|-------------|------------|
| Bruit du corpus Wikidata (classes parasites) | Carte polluée | Haute | Liste noire de classes, seuil d'importance (sitelinks), curation continue |
| Performance carte avec forte densité d'événements | UX dégradée | Moyenne | Bornage serveur (bbox + fenêtre + importance), simplification des polygones, tuiles vectorielles en plan B (ADR 0007) |
| Durcissement des limites API Wikimedia | Ingestion ralentie | Moyenne | Batch lent, cache persistant, bascule dumps JSON possible (ADR 0003) |
| Frontières historiques contestées | Crédibilité | Moyenne | Transparence assumée (aplats flous), sources citées, page Sources (ADR 0004) |
| Fatigue du projet solo | Arrêt | Moyenne | MVP resserré, features livrables indépendamment |

## Métriques de succès par phase

| Phase | Métrique | Cible |
|-------|----------|-------|
| 1 | Parcours complet en production | Fonctionnel |
| 1 | Événements explorables avec résumé FR ou EN | > 25 000 |
| 1 | Réponse endpoint events (bbox monde, fenêtre 1 000 ans) | < 300 ms p95 |
| 2 | Première contribution externe acceptée | 1 |
