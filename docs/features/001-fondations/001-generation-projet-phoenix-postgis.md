# Issue #001 -- Génération du projet Phoenix et PostGIS

**Feature :** F01 -- Fondations
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** aucun

---

## Contexte

Le projet est réécrit de zéro en Elixir / Phoenix 1.8 LiveView (ADR 0001), le prototype Django/React étant abandonné. Cette issue crée le socle sur lequel toutes les autres reposent : l'application Phoenix générée, la base PostgreSQL + PostGIS en Docker pour le développement, la configuration des types géographiques Ecto (`geo_postgis`), et la séparation des schémas PostgreSQL par bounded context (`atlas` et `ingestion` dès maintenant, `accounts` et `contributions` en phase 2).

Ce qui doit être vrai à la fin de l'issue : un poste de développement avec Docker et asdf (ou mise) démarre l'application en trois commandes (`docker compose up -d`, `mix setup`, `mix phx.server`), la base expose PostGIS, et les schémas PG `atlas` et `ingestion` existent via migration. Aucun code métier n'est écrit ici : ni table, ni schéma Ecto de domaine.

Impact sur le reste du système : toutes les issues suivantes (#002 à #005, puis F02 et F03) supposent cet environnement reproductible. Les décisions figées ici (SRID 4326, types PostGIS via `geo_postgis`, schémas PG séparés) sont des lois du projet (voir CLAUDE.md, `.claude/rules/architecture.md`).

## User Story

> En tant que développeur, je veux générer le squelette Phoenix avec une base PostGIS conteneurisée et les schémas PostgreSQL du domaine afin de disposer d'un environnement de développement reproductible et prêt pour le code métier.

---

## Tâches

- [ ] Créer `.tool-versions` à la racine avec les dernières versions stables d'Erlang/OTP et d'Elixir compatibles Phoenix 1.8 (vérifier au moment de l'implémentation, par exemple `erlang 27.x` et `elixir 1.18.x-otp-27`). Ce fichier est la source de vérité des versions, y compris pour la CI (#003).
- [ ] Générer le projet : `mix phx.new amanogawa --no-mailer --no-dashboard --binary-id` (LiveView est le défaut en Phoenix 1.8 ; pas de mailer ni de dashboard conformément à la vue d'ensemble F01 ; `--binary-id` prépare les identifiants UUID du modèle de domaine).
- [ ] Vérifier le `.gitignore` généré par Phoenix et le compléter : `.env`, `assets/node_modules/` (npm arrive en #005), fichiers de dump éventuels. Vérifier que `.claude/`, `CLAUDE.md` et `AGENTS.md` ne sont jamais commités (règle absolue : ils restent hors dépôt, ne pas les ajouter au `.gitignore` versionné si le choix est de les garder localement ignorés via `.git/info/exclude`).
- [ ] Créer `docker-compose.yml` à la racine : service `db` basé sur l'image `postgis/postgis` avec un tag épinglé (par exemple `postgis/postgis:17-3.5`, vérifier le dernier tag stable), `POSTGRES_PASSWORD=postgres`, port `5432:5432`, volume nommé pour la persistance, healthcheck `pg_isready`.
- [ ] Ajouter la dépendance `{:geo_postgis, "~> 3.7"}` dans `mix.exs` (Jason est déjà présent via Phoenix).
- [ ] Définir le module `Amanogawa.PostgresTypes` (fichier `lib/amanogawa/postgres_types.ex`) avec `Postgrex.Types.define/3` incluant `Geo.PostGIS.Extension` et `json: Jason`, puis configurer `config :amanogawa, Amanogawa.Repo, types: Amanogawa.PostgresTypes` dans `config/config.exs`.
- [ ] Écrire la migration initiale `priv/repo/migrations/<timestamp>_create_postgis_and_schemas.exs` avec `up`/`down` explicites : `execute "CREATE EXTENSION IF NOT EXISTS postgis"`, `execute "CREATE SCHEMA IF NOT EXISTS atlas"`, `execute "CREATE SCHEMA IF NOT EXISTS ingestion"` (et les `DROP` correspondants dans `down`, sans toucher à l'extension si elle est partagée : documenter le choix dans la migration).
- [ ] Créer `.env.example` à la racine documentant les variables d'environnement attendues en production (`DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`), avec un commentaire par variable. Aucun secret réel, le dev fonctionne sans `.env`.
- [ ] Rédiger la section démarrage du `README.md` : prérequis (Docker, asdf ou mise), commandes (`docker compose up -d`, `mix setup`, `mix phx.server`), URL locale.
- [ ] Vérifier que `mix setup` (alias généré : deps, base, assets) passe de bout en bout sur base Docker vierge, puis `mix test` vert.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : test DataCase qui exécute `Repo.query!("SELECT postgis_version()")` et vérifie qu'une version est retournée (preuve que l'extension est active dans la base de test).
- [ ] **Happy path** : test DataCase qui exécute `Repo.query!("SELECT ST_SetSRID(ST_MakePoint(2.35, 48.85), 4326)")` et vérifie que le résultat est décodé en `%Geo.Point{coordinates: {2.35, 48.85}, srid: 4326}` (preuve que `Amanogawa.PostgresTypes` est branché).
- [ ] **Edge case** : test DataCase qui interroge `information_schema.schemata` et vérifie la présence des schémas `atlas` et `ingestion`.
- [ ] **Error case** : vérifier que `mix ecto.rollback` puis `mix ecto.migrate` sur la migration initiale s'exécutent sans erreur (le `down` est réversible), au minimum en vérification manuelle documentée dans la PR.
- [ ] **Limit case** : le test de la page d'accueil généré par Phoenix passe (réponse 200 sur `/`), garantissant que le pipeline web fonctionne avant toute personnalisation (#004).

### Property-based tests (si applicable)

- [ ] Non applicable : aucune logique de domaine dans cette issue. StreamData arrive en #002 et sera exercé dès le modèle temporel (F02).

### Doctests (si applicable)

- [ ] Non applicable : aucun module public avec logique pure.

### Tests d'intégration

- [ ] **Intégration** : `mix setup` depuis un clone vierge avec base Docker fraîche (volume supprimé) aboutit sans intervention manuelle. Vérifié manuellement ici, automatisé en CI par #003.

### Tests end-to-end (si applicable)

- [ ] Non applicable à ce stade (aucune interface métier).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `.tool-versions` (créer)
  - `docker-compose.yml` (créer)
  - `.env.example` (créer)
  - `.gitignore` (compléter le fichier généré)
  - `mix.exs` (dépendance `geo_postgis`)
  - `config/config.exs`, `config/dev.exs`, `config/test.exs`, `config/runtime.exs` (config Repo, types, connexion Docker)
  - `lib/amanogawa/postgres_types.ex` (créer)
  - `priv/repo/migrations/<timestamp>_create_postgis_and_schemas.exs` (créer)
  - `test/amanogawa/repo_postgis_test.exs` (créer, tests DataCase ci-dessus)
  - `README.md` (section démarrage)
- **Documentation de référence** : ADR 0001 (réécriture Elixir/Phoenix), ADR 0007 (PostGIS, SRID 4326), `.claude/memory/tech-stack.md`, `.claude/memory/domain-model.md`, hexdocs de `geo_postgis` (configuration des types Postgrex), page Docker Hub `postgis/postgis`.
- **Compétences requises** : génération et structure d'un projet Phoenix 1.8, migrations Ecto avec `execute/1`-`execute/2`, Docker Compose, bases de la configuration Postgrex.
- **Points d'attention** :
  - Épingler le tag de l'image PostGIS : jamais `latest` (reproductibilité dev/CI).
  - La convention de nommage de la base de test générée par Phoenix (`amanogawa_test#{partition}`) doit rester intacte pour le sandbox Ecto.
  - Ne créer aucune table métier : les schémas PG sont vides, les tables arrivent avec leurs contextes (F02+). Chaque futur schéma Ecto déclarera `@schema_prefix`.
  - Rappel des lois du projet : SRID 4326 partout, jamais de type `date` PostgreSQL pour les dates historiques (année signée + précision, voir ADR 0006).
  - Ne pas committer `.claude/`, `CLAUDE.md`, `AGENTS.md` ; commit conventionnel en anglais, par exemple `chore(infra): generate phoenix project with postgis foundations`.
