# Documentation Amanogawa

Date : 2026-07-23
Version : 1.0

Index général de la documentation. Le code reste la source de vérité ; ces documents portent les décisions, les spécifications et le plan.

## Organisation

| Dossier / fichier | Contenu |
|-------------------|---------|
| [roadmap.md](roadmap.md) | Document chapeau : vision, phases, features, dépendances, risques |
| [adr/](adr/README.md) | Architecture Decision Records (numérotation continue, format Nygard) |
| [features/](features/) | Un dossier par feature : `000-slug.md` (vue d'ensemble) puis issues `001+.md` |
| [studies/](studies/) | Études ponctuelles (sources de données, explorations design) |
| [ops/](ops/) | Guides opérationnels (déploiement, sauvegardes) : à venir avec F06 |
| [archive/](archive/) | Ancien site statique 2022 sans rapport avec le projet |

## Conventions

- Documents stratégiques en français, accents corrects, ton professionnel, sans emoji.
- Pas de tiret cadratin ni demi-cadratin ; préférer virgule, deux-points, parenthèses.
- Markdown limité à 3 niveaux de titres ; diagrammes en ASCII ou Mermaid.
- Issues : numérotation locale par feature, id global conservé dans le titre (`# Issue #NNN`).
- Un ADR accepté ne se modifie pas : il se supersède.

## Démarrage rapide

1. Lire [roadmap.md](roadmap.md) pour le plan d'ensemble.
2. Lire les ADR [0001](adr/0001-reecriture-elixir-phoenix-liveview.md) à [0008](adr/0008-licence-agpl-principes-ethiques.md) pour les choix fondateurs.
3. Prendre une issue dans `features/` en respectant ses prérequis.
