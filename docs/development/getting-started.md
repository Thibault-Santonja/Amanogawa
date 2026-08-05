# Mise en route

Ce guide amène un environnement de développement fonctionnel, du clone du dépôt à une application qui répond, puis explique comment lancer les tests et diagnostiquer les problèmes courants. Il vise un développeur qui découvre le projet.

## Prérequis

| Outil | Version | Rôle |
|-------|---------|------|
| [Docker](https://docs.docker.com/get-docker/) | récente | Base PostgreSQL + PostGIS conteneurisée (image `postgis/postgis:18-3.6`) |
| Erlang/OTP | `28.5.0.3` | Machine virtuelle BEAM |
| Elixir | `1.19.5-otp-28` | Langage et outil `mix` |
| [Node.js](https://nodejs.org/) + npm | LTS récente | Dépendances front installées dans `assets/` |

Les versions d'Erlang et d'Elixir sont figées dans [`.tool-versions`](../../.tool-versions), source de vérité unique partagée avec la CI. Un gestionnaire de versions les installe automatiquement à la bonne version :

```sh
# avec asdf
asdf install

# ou avec mise
mise install
```

Google Chrome et un chromedriver compatible ne sont nécessaires que pour la suite de tests bout en bout (`mix test.e2e`) : voir [testing.md](testing.md). Un développeur qui ne lance jamais cette suite peut s'en passer.

## Installation pas à pas

### 1. Cloner le dépôt

```sh
git clone https://github.com/Thibault-Santonja/Amanogawa.git
cd Amanogawa
```

### 2. Installer les runtimes

```sh
asdf install     # ou: mise install
```

Vérifier que les versions actives correspondent à `.tool-versions` :

```sh
elixir --version
```

### 3. Démarrer la base de données

```sh
docker compose up -d
```

Le service `db` expose PostgreSQL avec PostGIS sur `127.0.0.1:5432` par défaut. L'image est publiée pour amd64 uniquement : sur Apple Silicon, `docker-compose.yml` force l'émulation `linux/amd64` (transparent, aucune action requise).

### 4. Installer et préparer le projet

```sh
mix setup
```

L'alias `mix setup` enchaîne : récupération des dépendances Hex (`deps.get`), création et migration de la base plus seeds (`ecto.setup`), installation de la chaîne d'assets (`assets.setup`, qui installe les binaires Tailwind et esbuild puis lance `npm install` dans `assets/`), et build initial des assets (`assets.build`).

### 5. Lancer le serveur

```sh
mix phx.server
```

L'application écoute sur [http://localhost:4000](http://localhost:4000). En développement, elle est liée à l'adresse de bouclage `127.0.0.1` (config/dev.exs) : elle n'est pas accessible depuis une autre machine.

Pour travailler avec une console `iex` attachée :

```sh
iex -S mix phx.server
```

Une base fraîche démarre vide : la carte et la frise n'affichent des événements qu'après un import. Voir [Peupler les données](../../README.md#peupler-les-données) et [`docs/ops/sync.md`](../ops/sync.md).

## Variables d'environnement

En développement et en test, aucun fichier `.env` n'est nécessaire : `config/dev.exs` et `config/test.exs` pointent vers la base Docker locale avec des valeurs par défaut. La seule variable utile en local est `POSTGRES_PORT` (voir les pièges ci-dessous).

Les variables ci-dessous sont lues par [`config/runtime.exs`](../../config/runtime.exs), essentiellement en production. Le contrat complet et commenté est dans [`.env.example`](../../.env.example).

| Variable | Défaut | Rôle |
|----------|--------|------|
| `POSTGRES_PORT` | `5432` | Port hôte de la base Docker (dev et test). À changer si `5432` est déjà pris. |
| `DATABASE_URL` | (requis en prod) | URL de connexion complète, ex. `ecto://user:pass@host/amanogawa_prod`. |
| `SECRET_KEY_BASE` | (requis en prod) | Clé de signature et chiffrement des cookies et sessions (`mix phx.gen.secret`). |
| `PHX_HOST` | (requis en prod) | Nom d'hôte public de l'application déployée. |
| `PORT` | `4000` | Port HTTP d'écoute (dev et prod ; le test est figé sur `4002`). |
| `POOL_SIZE` | `10` | Taille du pool Ecto. |
| `TRUSTED_PROXIES` | vide | IPs/CIDR des reverse-proxies de confiance pour `X-Forwarded-For`. Ne renseigner que derrière un proxy. |
| `RATE_LIMIT_PER_MINUTE` | `120` | Quota des endpoints JSON publics (prod). |
| `ALERT_RECIPIENT_EMAIL`, `ALERT_FROM_EMAIL`, `ALERT_ERROR_THRESHOLD`, `ALERT_WINDOW_MINUTES`, `ALERT_SILENCE_MINUTES` | voir `.env.example` | Alerting par email (prod). Laisser `ALERT_RECIPIENT_EMAIL` vide désactive l'alerting. |
| `SMTP_RELAY_HOST`, `SMTP_RELAY_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_SSL` | voir `.env.example` | Relais SMTP local pour l'alerting et les emails de connexion (magic link). |
| `MAGIC_LINK_RATE_LIMIT` | `5` | Requêtes de magic link autorisées par fenêtre de 15 minutes (prod). |

## Pièges connus

### Le port 5432 est déjà occupé

Symptôme classique quand une instance PostgreSQL locale (ou un autre projet) écoute déjà sur `5432` : le conteneur ne démarre pas, ou `mix setup` échoue à se connecter. Choisir un autre port hôte via `POSTGRES_PORT`, et l'exporter pour Docker **et** pour Mix, dans le même terminal :

```sh
export POSTGRES_PORT=5433
docker compose up -d
mix setup
mix phx.server
```

`config/dev.exs` et `config/test.exs` lisent tous deux `POSTGRES_PORT` (défaut `5432`), donc la même variable suffit à aligner l'application sur le port du conteneur.

### Le port 4000 de l'application

Le serveur de développement écoute sur `PORT` (défaut `4000`). En cas de conflit, lancer par exemple `PORT=4010 mix phx.server`. À noter : `PORT` n'est appliqué qu'en `:dev` et `:prod` ; l'environnement de test est figé sur le port `4002` (le vrai listener de la suite E2E), ce qui évite qu'un `mix test` entre en collision avec un serveur de dev déjà lancé sur `4000`.

## Lancer les tests

```sh
mix test
```

La suite unitaire et d'intégration s'appuie sur la même base Docker (base `amanogawa_test`, sandbox SQL). La suite bout en bout en est **exclue par défaut** ; elle se lance séparément :

```sh
mix test.e2e
```

`mix test.e2e` pilote un vrai navigateur (Google Chrome via chromedriver) et requiert donc ce couple installé localement. Le détail (installation, WebGL headless, variables `CHROMEDRIVER_PATH` / `CHROME_BINARY` pour un binaire local) est dans [testing.md](testing.md).

La barre de qualité complète, identique à la CI, se lance avec `mix precommit` (voir le [README](../../README.md#qualité)).

## Vérifier que tout fonctionne

Avec le serveur lancé (`mix phx.server`), l'endpoint de santé confirme que l'application et sa base répondent :

```sh
curl -i http://localhost:4000/health
```

Réponse attendue : `200 OK` avec un corps JSON `{"status":"ok","version":...}`. Si la base est inaccessible, l'endpoint renvoie `503` avec `{"status":"unavailable"}`.

La page principale (carte et frise) est servie sur la racine :

```sh
curl -i http://localhost:4000/
```

Elle répond `200` même sur une base vide (la carte s'affiche sans marqueur tant qu'aucun import n'a peuplé les événements).

## Dépannage

### `mix setup` échoue à se connecter à la base

Vérifier que le conteneur tourne et est sain :

```sh
docker compose ps
```

Le service `db` doit être `healthy` (healthcheck `pg_isready`). Si le port hôte a été changé, s'assurer que `POSTGRES_PORT` est bien exporté dans le terminal courant avant de relancer `mix setup`. Redémarrer la base au besoin : `docker compose restart db`.

### Warnings de compilation bloquants

Le projet compile avec `--warnings-as-errors` dans `mix precommit`. Un avertissement fait échouer le gate : le corriger, ne pas le contourner.

### Erreur de version Erlang/Elixir

Si `mix` refuse de démarrer sur une incompatibilité de version, revérifier que le gestionnaire de versions expose bien les versions de `.tool-versions` (`asdf current` ou `mise ls`), puis relancer `asdf install` / `mise install`.

### Assets non reconstruits

En développement, esbuild et Tailwind tournent en watchers lancés par le serveur (config/dev.exs) et rebuild à la volée. Pour forcer un build manuel : `mix assets.build`. Si les binaires manquent : `mix assets.setup`.

### La base contient des données incohérentes

Repartir d'une base propre (destructif : supprime et recrée la base de développement) :

```sh
mix ecto.reset
```
</content>
