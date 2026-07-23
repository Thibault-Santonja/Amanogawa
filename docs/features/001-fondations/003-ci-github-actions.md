# Issue #003 -- CI GitHub Actions

**Feature :** F01 -- Fondations
**Priorité :** Haute
**Estimation :** 4h
**Prérequis :** #002

---

## Contexte

La barre de qualité définie en #002 (`mix precommit`, couverture > 90 %, audit des dépendances) doit être appliquée automatiquement à chaque push et pull request : c'est la garantie que le dépôt principal reste toujours vert. Cette issue met en place le workflow GitHub Actions qui rejoue exactement le precommit local, avec une base PostGIS de service (les tests DataCase de #001 exigent l'extension PostGIS) et un cache des dépendances pour garder des exécutions courtes.

Principe directeur : zéro divergence entre local et CI. La CI n'invente aucune étape, elle exécute `mix precommit`, puis la couverture et l'audit. Aucun service tiers de couverture (type Codecov ou Coveralls.io) n'est utilisé, en cohérence avec l'esprit d'autonomie du projet (ADR 0008) : le rapport s'affiche dans les logs et le seuil est bloquant via excoveralls.

## User Story

> En tant que mainteneur, je veux que chaque push et chaque pull request exécutent automatiquement compile, format, credo, sobelow, tests, couverture et audit des dépendances, afin qu'aucune régression de qualité n'atteigne la branche principale.

---

## Tâches

- [ ] Créer `.github/workflows/ci.yml` :
  - Déclencheurs : `push` sur `main` et `pull_request`.
  - `concurrency` par ref avec `cancel-in-progress: true` (pas d'exécutions redondantes).
  - Job `test` sur `ubuntu-latest`, avec `MIX_ENV: test` dans l'environnement du job.
- [ ] Service PostGIS dans le job : image identique au `docker-compose.yml` de #001 (par exemple `postgis/postgis:17-3.5`), `POSTGRES_PASSWORD: postgres`, port `5432:5432`, options de healthcheck `pg_isready` (`--health-cmd`, `--health-interval`, `--health-timeout`, `--health-retries`) pour que les steps attendent une base prête.
- [ ] Steps :
  1. `actions/checkout@v4`
  2. `erlef/setup-beam@v1` avec `version-file: .tool-versions` et `version-type: strict` (source de vérité unique des versions, voir #001)
  3. `actions/cache@v4` sur `deps/` et `_build/` avec une clé composée de l'OS, du contenu de `.tool-versions` et du hash de `mix.lock`, plus une `restore-keys` de repli
  4. `mix deps.get`
  5. `mix precommit` (l'alias de #002, à l'identique)
  6. `mix coveralls` (échoue sous 90 %, voir `coveralls.json`)
  7. `mix deps.audit`
- [ ] Vérifier que la config `config/test.exs` (host `localhost`, port 5432, mot de passe `postgres`) fonctionne telle quelle contre le service CI, sans variable spécifique ; sinon aligner via variables d'environnement standard (`DATABASE_URL` ou équivalent) en modifiant le moins possible.
- [ ] Ajouter le badge de statut du workflow en tête du `README.md` (badge natif GitHub Actions, aucun service tiers).
- [ ] Valider le workflow sur une branche : un run vert complet, et un run rouge provoqué (test cassé volontairement sur une branche jetable, supprimée ensuite).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : le workflow passe au vert sur une branche à jour de #001 et #002 (compile, format, credo, sobelow, tests, couverture, audit).
- [ ] **Edge case** : premier run sans cache (cache miss) et run suivant avec cache (cache hit) passent tous les deux ; le run avec cache est nettement plus court (observation des durées dans l'interface Actions).
- [ ] **Error case** : un test volontairement cassé sur une branche jetable met le workflow au rouge à l'étape `mix precommit` (branche supprimée après vérification).
- [ ] **Limit case** : une couverture sous le seuil (exclusion temporaire d'un fichier de test sur branche jetable) met le workflow au rouge à l'étape `mix coveralls`.

### Property-based tests (si applicable)

- [ ] Non applicable : aucune logique applicative.

### Doctests (si applicable)

- [ ] Non applicable.

### Tests d'intégration

- [ ] **Intégration** : le job complet démarre le service PostGIS, migre la base de test et exécute la suite DataCase de #001 (preuve que le pipeline CI reproduit l'environnement local Docker).

### Tests end-to-end (si applicable)

- [ ] Non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `.github/workflows/ci.yml` (créer)
  - `README.md` (badge de statut)
  - `config/test.exs` (uniquement si l'alignement avec le service CI l'exige)
- **Documentation de référence** : #001 (image PostGIS, `.tool-versions`), #002 (alias `precommit`, `coveralls.json`), documentation `erlef/setup-beam`, `actions/cache`, documentation GitHub Actions sur les services de conteneurs, ADR 0008 (pas de service tiers).
- **Compétences requises** : GitHub Actions (services, cache, concurrency), cycle de vie d'une app Phoenix en CI (deps, compile, base de test).
- **Points d'attention** :
  - La clé de cache doit inclure `.tool-versions` : un changement de version OTP/Elixir invalide `_build`, sinon erreurs de compilation incompréhensibles.
  - Le tag de l'image PostGIS doit rester synchronisé avec `docker-compose.yml` : toute montée de version se fait dans les deux fichiers dans le même commit.
  - Ne pas dupliquer les étapes du precommit en steps séparés : appeler l'alias, c'est lui le contrat.
  - `mix deps.audit` dépend d'une base de vulnérabilités distante : en cas d'alerte sur une dépendance, appliquer la règle des vitres cassées (mettre à jour ou documenter immédiatement, pas d'exclusion silencieuse).
  - Le badge référence le workflow du dépôt lui-même : pas de service externe de badge.
