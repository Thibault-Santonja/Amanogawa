# F01 -- Fondations

> Phase 1 | Priorité P0 | Estimation : 1 semaine

## Résumé

Créer le socle du projet : application Phoenix 1.8 LiveView, PostgreSQL + PostGIS en Docker pour le dev, outillage qualité complet (precommit, Credo strict, Sobelow, excoveralls > 90 %, deps.audit), CI GitHub Actions, design tokens Tailwind v4, et une carte MapLibre vide qui s'affiche (preuve de bout en bout du pipeline d'assets et du hook).

## Analyse

### Architecture

- Projet généré avec `mix phx.new amanogawa` (LiveView, sans mailer ni dashboard pour l'instant), structure par bounded contexts prévue (voir CLAUDE des agents et memory) : `lib/amanogawa/` (atlas, ingestion) et `lib/amanogawa_web/`.
- PostGIS via l'image `postgis/postgis` en docker-compose ; extension activée par migration ; `geo_postgis` configuré dans les types Ecto.
- Schémas PostgreSQL séparés créés dès le départ : `atlas`, `ingestion` (accounts et contributions en phase 2).
- Alias `mix precommit` : compile --warnings-as-errors, format --check-formatted, credo --strict, sobelow, test.
- Assets : esbuild + Tailwind v4 (config CSS-first), MapLibre GL JS et d3 vendorés via npm (pas de CDN, CSP stricte).

### Sécurité

- CSP stricte dès le layout initial ; aucun script tiers.
- `.env.example` documente les variables ; aucun secret commité.

### Performance

- Budget JS surveillé dès le départ (MapLibre ~230 KB gzip, d3 modules ~30 KB) ; pas d'autre dépendance front.

### Éthique

- Fond de carte : tuiles vectorielles OpenFreeMap ou Protomaps (PMTiles auto-hébergé), à trancher dans l'issue #005 selon qualité visuelle et conditions d'usage ; pas de Google/Mapbox.

## User Stories

- GIVEN un poste de dev avec Docker, WHEN je lance `docker compose up` puis `mix setup && mix phx.server`, THEN l'application démarre avec PostGIS et affiche la page d'accueil avec une carte du monde vide.
- GIVEN un commit poussé, WHEN la CI s'exécute, THEN compile, format, credo, sobelow, tests et couverture sont vérifiés.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #001 Génération du projet Phoenix + PostGIS | 001-generation-projet-phoenix-postgis.md | 8h |
| #002 Outillage qualité et precommit | 002-outillage-qualite-precommit.md | 6h |
| #003 CI GitHub Actions | 003-ci-github-actions.md | 4h |
| #004 Layout, design tokens Tailwind, dark mode | 004-layout-design-tokens.md | 8h |
| #005 Fond de carte vectoriel + MapHook minimal | 005-fond-de-carte-maphook.md | 8h |

## Dépendances

- Prérequis : aucun.
- Sortie : F02 (ingestion), F03 (carte), F06 (déploiement).
