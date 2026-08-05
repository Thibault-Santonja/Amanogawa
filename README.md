# Amanogawa (天の川)

[![CI](https://github.com/Thibault-Santonja/Amanogawa/actions/workflows/ci.yml/badge.svg)](https://github.com/Thibault-Santonja/Amanogawa/actions/workflows/ci.yml)

Rendre l'histoire visible : une carte du monde et une frise chronologique interactives pour explorer les événements historiques, de la préhistoire à aujourd'hui.

Les événements sont issus de Wikidata et Wikipedia. Chaque événement est placé sur la carte (point ou zone), positionné sur la frise, relié aux événements qui lui sont liés, et renvoie vers son article Wikipedia. Les zones d'influence des entités politiques s'affichent en fond de carte selon la période sélectionnée. Une surcouche de contribution collaborative, éthique et transparente, permet de proposer des corrections sans jamais écraser silencieusement les données sources.

Principes fondateurs : zéro tracking, AGPL-3.0, auto-hébergeable, respect de l'étiquette Wikimedia, attribution des sources.

## Sommaire

- [Vision et état du projet](#vision-et-état-du-projet)
- [Stack technique](#stack-technique)
- [Prérequis](#prérequis)
- [Démarrage rapide](#démarrage-rapide)
- [Peupler les données](#peupler-les-données)
- [Qualité](#qualité)
- [Tests](#tests)
- [Structure du projet](#structure-du-projet)
- [Documentation](#documentation)
- [Déploiement](#déploiement)
- [Sources de données et licences](#sources-de-données-et-licences)
- [Licence](#licence)
- [Contribuer](#contribuer)

## Vision et état du projet

Rendre l'histoire visible : carte et frise interactives, événements Wikidata/Wikipedia, frontières historiques en fond de carte, relations tracées entre événements, et un éditeur collaboratif ouvert. Le plan complet, les phases et les décisions de cadrage sont dans [`docs/roadmap.md`](docs/roadmap.md).

Les huit features des deux phases (MVP exploration en lecture seule, puis collaboratif) sont développées, revues et mergées. Restent à la charge de l'opérateur le déploiement réel et les imports de données réels (voir [Peupler les données](#peupler-les-données) et [`docs/ops/deploy.md`](docs/ops/deploy.md)).

## Stack technique

| Domaine | Choix |
|---------|-------|
| Application | Phoenix 1.8, LiveView (aucun framework JS) |
| Base de données | PostgreSQL + PostGIS (géométries SRID 4326) |
| Jobs de fond | Oban (pipelines d'ingestion, synchronisation mensuelle) |
| Carte | MapLibre GL JS (hook LiveView vanilla), tuiles OpenFreeMap |
| Frise | d3 (échelle et zoom uniquement, hook LiveView vanilla) |
| Styles | Tailwind CSS v4 |
| HTTP sortant | Req (SPARQL QLever, API REST Wikipedia) |
| Déploiement | Kamal 2 sur VPS Docker |

Les décisions d'architecture sont consignées dans [`docs/adr/`](docs/adr/README.md).

## Prérequis

- [Docker](https://docs.docker.com/get-docker/) : base PostgreSQL + PostGIS conteneurisée en développement.
- [asdf](https://asdf-vm.com/) ou [mise](https://mise.jdx.dev/) : les versions d'Erlang/OTP et d'Elixir sont lues dans [`.tool-versions`](.tool-versions) (Erlang `28.5.0.3`, Elixir `1.19.5-otp-28`), source de vérité unique partagée avec la CI.
- [Node.js](https://nodejs.org/) avec npm : dépendances front installées dans `assets/` par `mix setup`.
- Google Chrome + chromedriver : uniquement pour la suite de tests bout en bout (`mix test.e2e`), inutile autrement.

## Démarrage rapide

```sh
git clone https://github.com/Thibault-Santonja/Amanogawa.git
cd Amanogawa

docker compose up -d     # démarre PostgreSQL + PostGIS
mix setup                # dépendances, base de données, assets
mix phx.server           # démarre l'application
```

L'application est disponible sur [http://localhost:4000](http://localhost:4000).

Si le port `5432` est déjà occupé sur la machine (autre instance PostgreSQL), choisir un autre port hôte via la variable `POSTGRES_PORT`, pour Docker comme pour Mix, dans le même terminal :

```sh
export POSTGRES_PORT=5433
docker compose up -d
mix setup
mix phx.server
```

Le guide détaillé (installation pas à pas, variables d'environnement, dépannage) est dans [`docs/development/getting-started.md`](docs/development/getting-started.md).

## Peupler les données

Une base fraîche démarre vide : la carte et la frise n'affichent des événements qu'après un import. Les imports sont manuels et se lancent sur l'application démarrée (accès à la base et à Internet requis).

Événements, relations et résumés (Wikidata puis Wikipedia), dans cet ordre :

```sh
mix amanogawa.sync events
mix amanogawa.sync links
mix amanogawa.sync summaries
```

Frontières historiques (fichiers téléchargés manuellement au préalable, jamais versionnés) :

```sh
mix amanogawa.import.cliopatria PATH             # Cliopatria (GeoJSON)
mix amanogawa.import.historical_basemaps PATH    # tranches préhistoriques historical-basemaps
```

Volumétrie attendue, durées, `--dry-run`, `--limit`, reprise après échec et planification mensuelle automatique (Oban Cron) : voir [`docs/ops/sync.md`](docs/ops/sync.md). Le détail de chaque import de frontières (téléchargement, vérification de checksum, idempotence) est documenté dans l'aide des tâches (`mix help amanogawa.import.cliopatria`, `mix help amanogawa.import.historical_basemaps`).

## Qualité

La barre de qualité est appliquée en local et en CI par la même commande :

```sh
mix precommit
```

Elle enchaîne, dans cet ordre (échec au premier problème) : compilation avec warnings bloquants (`compile --warnings-as-errors`), vérification du formatage (`format --check-formatted`), analyse statique ([Credo](https://hexdocs.pm/credo/) en mode strict), analyse de sécurité ([Sobelow](https://hexdocs.pm/sobelow/)), build des assets (`assets.build`), tests unitaires JavaScript (`npm test` dans `assets/`), puis les tests Elixir. Elle doit passer avant chaque commit.

Commandes complémentaires :

```sh
mix coveralls        # couverture de tests, échoue sous le seuil de 90 %
mix coveralls.html   # rapport détaillé dans cover/excoveralls.html
mix deps.audit       # audit des vulnérabilités des dépendances
```

La CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) rejoue exactement `mix precommit`, puis `mix coveralls` (seuil de 90 % minimum, voir [`coveralls.json`](coveralls.json)) et `mix deps.audit`, à quoi s'ajoutent trois jobs dédiés : suite E2E navigateur, `shellcheck` des scripts d'exploitation, et build de l'image Docker de production. Aucune divergence entre le local et la CI.

## Tests

```sh
mix test        # suite unitaire et d'intégration (la suite E2E en est exclue par défaut)
mix test.e2e    # suite bout en bout, pilotée par un vrai navigateur
```

`mix test.e2e` requiert Google Chrome et un chromedriver compatible installés localement ; un développeur qui ne lance jamais cette suite n'en a pas besoin. Le détail (installation du couple Chrome/chromedriver, exécution, WebGL headless) est dans [`docs/development/testing.md`](docs/development/testing.md).

## Structure du projet

```
lib/amanogawa/          # Couche métier : contextes bornés (Atlas, Ingestion, Accounts, Contributions)
lib/amanogawa_web/      # Couche web : LiveViews, composants, contrôleurs API, plugs
lib/mix/tasks/          # Tâches Mix d'exploitation (amanogawa.sync, imports de frontières)
assets/                 # Front : hooks JS (carte, frise), CSS, styles de carte vendorés
config/                 # Configuration par environnement (config, dev, test, runtime)
priv/repo/              # Migrations et seeds
test/                   # Miroir de lib/, plus la suite E2E (test/e2e/)
docs/                   # Documentation versionnée (development/, adr/, features/, ops/, roadmap)
```

Carte détaillée du code, contextes bornés et séparation des schémas PostgreSQL : voir [`docs/development/codebase-map.md`](docs/development/codebase-map.md).

## Documentation

- [`docs/development/`](docs/development/README.md) : guide développeur (mise en route, architecture, carte du code, ajout d'une feature, tests).
- [`docs/adr/`](docs/adr/README.md) : Architecture Decision Records (décisions fondatrices, format Nygard).
- [`docs/features/`](docs/features/) : une spécification par feature (`000-slug.md` puis issues détaillées).
- [`docs/ops/`](docs/ops/) : guides d'exploitation ([déploiement](docs/ops/deploy.md), [synchronisation](docs/ops/sync.md), [sauvegardes et restauration](docs/ops/restore.md), [modération](docs/ops/moderation.md)).
- [`docs/roadmap.md`](docs/roadmap.md) : vision, phases, features, risques.

## Déploiement

Kamal 2 sur un VPS Docker, PostgreSQL avec l'extension PostGIS, zéro analytics tiers, auto-hébergeable (ADR 0008). Le `Dockerfile` et `config/deploy.yml` restent génériques : toute valeur propre à un déploiement est un placeholder listé et documenté dans [`docs/ops/deploy.md`](docs/ops/deploy.md). Les variables d'environnement de production sont décrites dans [`.env.example`](.env.example) et lues par [`config/runtime.exs`](config/runtime.exs).

## Sources de données et licences

Attribution obligatoire partout où les données sont affichées (crédits de carte, page Sources).

| Source | Usage | Licence |
|--------|-------|---------|
| [Wikidata](https://www.wikidata.org/) | Événements, dates, coordonnées, relations | CC0 |
| [Wikipedia](https://www.wikipedia.org/) | Résumés et liens vers les articles | CC BY-SA 4.0 |
| [Cliopatria / Seshat](https://github.com/Seshat-Global-History-Databank/cliopatria) | Frontières historiques | CC BY 4.0 |
| [historical-basemaps](https://github.com/aourednik/historical-basemaps) | Frontières préhistoriques (complément) | GPL-3.0 |
| [OpenFreeMap](https://openfreemap.org/) / [OpenStreetMap](https://www.openstreetmap.org/copyright) | Fond de tuiles vectorielles | ODbL |

Le fond de carte est servi par l'instance publique OpenFreeMap (tuiles OpenMapTiles, sans clé API, sans cookie ni suivi). Les styles MapLibre sont vendorés dans `assets/vendor/map-styles/` ; seuls les tuiles, glyphes et sprites sont récupérés sur `https://tiles.openfreemap.org`, seule origine distante autorisée par la Content-Security-Policy. L'attribution `© OpenStreetMap contributors` (ODbL) est déclarée dans les styles et ne doit jamais disparaître de la carte.

## Licence

[AGPL-3.0](LICENSE). Dépôt public. Voir l'ADR [0008](docs/adr/0008-licence-agpl-principes-ethiques.md) pour les principes éthiques non négociables.

## Contribuer

Les conventions absolues, le workflow et la marche à suivre sont dans [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Historique

Ce dépôt a hébergé un prototype Django + React (2020-2022), conservé dans l'historique git. Un ancien site statique sans rapport avec le projet est archivé dans `docs/archive/2022-site-html/`.
</content>
</invoke>
