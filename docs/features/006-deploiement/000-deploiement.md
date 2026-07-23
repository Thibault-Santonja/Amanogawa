# F06 -- Déploiement et pages légales

> Phase 1 | Priorité P1 | Estimation : 1 semaine

## Résumé

Mettre le MVP en production : Dockerfile de release, Kamal 2 sur VPS Hetzner, PostgreSQL + PostGIS géré, sauvegardes, healthcheck et logs structurés. Page Sources / À propos avec toutes les attributions (Wikidata CC0, Wikipedia CC BY-SA 4.0, Cliopatria CC BY 4.0, historical-basemaps GPL-3.0, fond de carte), mentions légales et politique de confidentialité (triviale : zéro tracking).

## Analyse

### Architecture

- Release Elixir standard (mix release), image distroless ou debian-slim, healthcheck `/health` (DB + version).
- Kamal 2 : deploy sur le VPS Hetzner mutualisé existant (patterns des autres projets), secrets via .kamal/secrets, accessory PostgreSQL avec image postgis.
- Sauvegardes : pg_dump quotidien vers stockage séparé, procédure de restauration documentée dans `docs/ops/restore.md`.
- Observabilité minimale : logs JSON, erreurs 5xx alertées (sans service tiers de tracking).

### Éthique / Légal

- Page Sources : liste exhaustive des sources, licences et liens ; formulation claire de l'imprécision des frontières.
- Politique de confidentialité : aucun cookie anonyme, aucune donnée collectée en phase 1.

## User Stories

- GIVEN un commit sur main avec CI verte, WHEN je lance `kamal deploy`, THEN la nouvelle version est en production sans interruption et le healthcheck passe.
- GIVEN la production, WHEN un visiteur ouvre la page Sources, THEN toutes les attributions et licences sont présentes.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #026 Dockerfile release + Kamal 2 + PostGIS prod | 001-dockerfile-kamal.md | 12h |
| #027 Page Sources / À propos + confidentialité | 002-page-sources-legal.md | 6h |
| #028 Sauvegardes et observabilité (le healthcheck est porté par #026) | 003-sauvegardes-observabilite.md | 8h |

## Dépendances

- Prérequis : F01 ; déployable dès F03 (une carte avec événements suffit pour une première mise en ligne).
- Sortie : MVP public.
