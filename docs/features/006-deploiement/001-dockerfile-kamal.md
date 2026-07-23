# Issue #026 -- Dockerfile de release et déploiement Kamal 2

**Feature :** F06 -- Déploiement et pages légales
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #003

---

## Contexte

Le MVP doit être mis en production sur le VPS Hetzner mutualisé, avec les mêmes patterns Kamal 2 que les autres projets de l'auteur (shuyuan, Seigneurie). Cette issue construit toute la chaîne : image Docker de release Elixir, configuration Kamal 2 (application, accessory PostgreSQL avec PostGIS, proxy TLS, secrets), healthcheck `/health`, migrations exécutées au déploiement, et déploiement sans interruption de service.

Le problème résolu : aujourd'hui l'application ne tourne qu'en développement local (docker compose pour PostGIS, `mix phx.server`). Il n'existe ni image de production, ni procédure de mise en ligne reproductible.

Insertion dans l'architecture : cette issue n'ajoute aucune logique métier. Elle ajoute la couche infrastructure (Dockerfile, `config/deploy.yml`, module `Amanogawa.Release`), un endpoint web technique (`/health`) et la documentation d'exploitation (`docs/ops/deploy.md`). Le projet étant AGPL-3.0 et auto-hébergeable (ADR 0008), le Dockerfile est aussi le chemin officiel d'auto-hébergement : il doit rester générique (aucune valeur spécifique au VPS de production en dur).

Impact sur le reste du système : le healthcheck devient le contrat de disponibilité utilisé par kamal-proxy pour basculer le trafic ; les migrations doivent désormais rester compatibles avec la version précédente de l'application (contrainte de zéro downtime) ; la CI (#003) gagne une étape de build d'image pour détecter les régressions du Dockerfile.

## User Story

> En tant que mainteneur du projet, je veux déployer une nouvelle version en une commande (`kamal deploy`) sans interruption de service, afin de mettre le MVP en ligne et de publier des correctifs sereinement.

---

## Tâches

- [ ] Écrire le `Dockerfile` multi-stage :
  - Stage `builder` : image `hexpm/elixir` (version Elixir/OTP du projet, variante debian-bookworm-slim, tag épinglé), `MIX_ENV=prod`, `mix deps.get --only prod`, compilation, `mix assets.deploy` (esbuild + Tailwind, MapLibre et d3 vendorés, aucun CDN), `mix release`.
  - Stage `runtime` : `debian:bookworm-slim` épinglé, paquets minimaux (`libstdc++6`, `openssl`, `ca-certificates`, `locales`), locale UTF-8, utilisateur non-root dédié (`amanogawa`, uid fixe), copie de la release avec `chown`, `USER amanogawa`, `EXPOSE 4000`, entrée sur le script de démarrage.
- [ ] Écrire `.dockerignore` (tout exclure par défaut puis autoriser le nécessaire : `mix.exs`, `mix.lock`, `config/`, `lib/`, `priv/`, `assets/`, `rel/`).
- [ ] Créer `lib/amanogawa/release.ex` : `migrate/0` et `rollback/2` via `Ecto.Migrator` (chargement de l'application sans Mix, pattern release standard), couvrant les schémas PostgreSQL `atlas` et `ingestion`.
- [ ] Exécuter les migrations au déploiement : script d'entrée `rel/overlays/bin/docker-entrypoint` qui lance `bin/amanogawa eval "Amanogawa.Release.migrate()"` puis `exec bin/amanogawa start`. Le verrou de migration d'`Ecto.Migrator` protège du démarrage concurrent de deux conteneurs pendant le rolling deploy. Documenter la contrainte associée : toute migration doit être rétrocompatible avec la version N-1 du code (pas de suppression de colonne utilisée, pattern expand/contract).
- [ ] Implémenter le healthcheck :
  - `GET /health` dans le router (pipeline minimal, hors rate limiting, hors CSRF).
  - `AmanogawaWeb.HealthController` : vérifie la base (`SELECT 1` via un module `Amanogawa.HealthCheck` derrière un behaviour pour la testabilité), répond `200` avec `{"status": "ok", "version": "..."}` (version lue via `Application.spec(:amanogawa, :vsn)`), ou `503` avec `{"status": "unavailable"}` si la base est injoignable.
  - Aucune information sensible dans la réponse (pas d'URL de base, pas de hostname, pas de stacktrace).
- [ ] Écrire `config/deploy.yml` (Kamal 2) :
  - `service: amanogawa`, image poussée sur un registry (ghcr.io), serveur web = VPS Hetzner mutualisé.
  - `proxy` : `ssl: true` (certificat Let's Encrypt géré par kamal-proxy), `host` du domaine, `healthcheck` sur `/health` (path, interval, timeout), pour garantir la bascule sans coupure.
  - `accessories.db` : image `postgis/postgis` (tag majeur épinglé, cohérent avec la version PostgreSQL du docker-compose de dev), volume de données persistant, port PostgreSQL exposé uniquement sur le réseau Docker privé (jamais public), variables d'initialisation via secrets.
  - `env` : `clear` (`PHX_HOST`, `PORT`, `POOL_SIZE`) et `secret` (`SECRET_KEY_BASE`, `DATABASE_URL`).
- [ ] Gérer les secrets : `.kamal/secrets` lu depuis l'environnement ou un gestionnaire de mots de passe, JAMAIS commité ; ajouter `.kamal/secrets*` au `.gitignore` ; fournir `.kamal/secrets.example` documentant les variables requises (`KAMAL_REGISTRY_PASSWORD`, `SECRET_KEY_BASE`, `DATABASE_URL`, `POSTGRES_PASSWORD`) sans aucune valeur réelle.
- [ ] Vérifier `config/runtime.exs` : lecture de `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`, `PORT` ; `server: true` piloté par `PHX_SERVER` ; erreurs explicites si une variable obligatoire manque ; `.env.example` mis à jour.
- [ ] Ajouter le build de l'image à la CI (#003) : job `docker build` sans push, pour casser la CI si le Dockerfile régresse.
- [ ] Rédiger `docs/ops/deploy.md` : prérequis (Docker, Kamal 2, accès SSH, registry), premier déploiement (`kamal setup`), déploiement courant (`kamal deploy`), rollback (`kamal rollback`), consultation des logs (`kamal app logs`), console distante (`kamal app exec -i "bin/amanogawa remote"`), gestion des secrets, checklist de smoke test post-déploiement (`curl /health`, page d'accueil, certificat TLS valide).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `GET /health` répond `200` avec un JSON contenant `status: "ok"` et une `version` égale à `Application.spec(:amanogawa, :vsn)` (check DB simulé en succès via Mox sur le behaviour `Amanogawa.HealthCheck`).
- [ ] **Edge case** : la réponse de `/health` ne contient aucune clé autre que celles attendues (pas de fuite d'information : ni hostname, ni configuration, ni détail d'erreur).
- [ ] **Error case** : quand le check DB échoue (Mox simule une exception ou un retour d'erreur), `/health` répond `503` avec `status: "unavailable"` sans stacktrace dans le corps.
- [ ] **Limit case** : le check DB dépasse son timeout (Mox simule la lenteur) : la réponse est `503` dans un délai borné, le controller ne bloque pas indéfiniment.

### Property-based tests (si applicable)

- [ ] Non applicable : pas de logique de parsing ni de modèle temporel dans cette issue.

### Doctests (si applicable)

- [ ] Non applicable : `Amanogawa.Release` dépend du runtime de release, pas d'exemple pur pertinent.

### Tests d'intégration

- [ ] **Intégration** : via `ConnCase` avec la vraie base de test PostGIS, `GET /health` répond `200` (chaîne complète router, controller, `SELECT 1`).
- [ ] **Intégration** : `/health` est accessible sans session, sans cookie, et n'émet pas d'en-tête `set-cookie`.

### Tests end-to-end (si applicable)

- [ ] **E2E** : checklist manuelle de smoke test post-déploiement documentée dans `docs/ops/deploy.md` et exécutée lors du premier déploiement réel : `curl https://<domaine>/health` répond 200, la page d'accueil s'affiche, le certificat TLS est valide, `kamal deploy` d'une version N+1 ne provoque aucune requête en erreur pendant la bascule.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `Dockerfile`, `.dockerignore`
  - `rel/overlays/bin/docker-entrypoint`
  - `lib/amanogawa/release.ex`
  - `lib/amanogawa/health_check.ex` (behaviour + implémentation Repo)
  - `lib/amanogawa_web/controllers/health_controller.ex`
  - `lib/amanogawa_web/router.ex` (route `/health`)
  - `config/deploy.yml`, `.kamal/secrets.example`, `.gitignore`
  - `config/runtime.exs`, `.env.example`
  - `.github/workflows/ci.yml` (job de build d'image)
  - `docs/ops/deploy.md`
  - `test/amanogawa_web/controllers/health_controller_test.exs`, `test/support/mocks.ex` (Mox pour le behaviour)
- **Documentation de référence** : ADR 0008 (AGPL, auto-hébergement), `.claude/memory/tech-stack.md` (Kamal 2 sur VPS Hetzner), `.claude/rules/security.md` (aucun secret dans le dépôt, variables via `runtime.exs`), guide Phoenix "Deploying with Releases", documentation Kamal 2 (accessories, proxy, secrets).
- **Compétences requises** : releases Elixir (`mix release`, `Ecto.Migrator` sans Mix), Docker multi-stage, Kamal 2 (deploy, accessories, kamal-proxy), notions TLS/Let's Encrypt.
- **Points d'attention** :
  - Épingler précisément les tags d'images (builder, runtime, postgis) : les versions Elixir/OTP de l'image builder doivent correspondre à `.tool-versions` ou au `mix.exs` du projet.
  - L'utilisateur non-root doit posséder les répertoires accédés en écriture au runtime (tmp de la release).
  - Le port de l'accessory PostgreSQL ne doit jamais être exposé publiquement : réseau Docker privé uniquement.
  - Zéro downtime : c'est la combinaison healthcheck + kamal-proxy + migrations rétrocompatibles qui le garantit ; les trois vont ensemble.
  - `/health` reste hors rate limiting (kamal-proxy l'appelle fréquemment) mais ne doit déclencher aucune écriture.
  - Aucune valeur spécifique à la production en dur dans le Dockerfile : tout passe par l'environnement (auto-hébergement, ADR 0008).
  - Les sauvegardes, logs JSON et alerting sont hors périmètre : issue #028.
