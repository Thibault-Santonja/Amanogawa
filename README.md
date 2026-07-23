# Amanogawa (天の川)

[![CI](https://github.com/Thibault-Santonja/Amanogawa/actions/workflows/ci.yml/badge.svg)](https://github.com/Thibault-Santonja/Amanogawa/actions/workflows/ci.yml)

Rendre l'histoire visible : une carte du monde et une frise chronologique interactives pour explorer les événements historiques, de la préhistoire à aujourd'hui.

Les événements sont issus de Wikidata et Wikipedia : chaque événement est placé sur la carte (point ou zone), positionné sur la frise, relié aux événements qui lui sont liés, et renvoie vers son article Wikipedia. Les zones d'influence des entités politiques s'affichent en fond de carte selon la période sélectionnée.

## Statut

Projet en phase de cadrage. Voir `docs/roadmap.md` pour le plan et `docs/adr/` pour les décisions d'architecture.

## Stack

- Elixir / Phoenix LiveView
- PostgreSQL + PostGIS
- Tailwind CSS, MapLibre GL JS (hook LiveView)

## Démarrage

Prérequis :

- [Docker](https://docs.docker.com/get-docker/) (base PostgreSQL + PostGIS conteneurisée)
- [asdf](https://asdf-vm.com/) ou [mise](https://mise.jdx.dev/) (versions d'Erlang/OTP et d'Elixir lues dans `.tool-versions`)

Lancement en trois commandes :

```sh
docker compose up -d     # démarre PostgreSQL + PostGIS
mix setup                # dépendances, base de données, assets
mix phx.server           # démarre l'application
```

L'application est disponible sur [http://localhost:4000](http://localhost:4000).

Si le port 5432 est déjà occupé sur la machine (autre instance PostgreSQL), choisir un autre port hôte via la variable `POSTGRES_PORT`, pour Docker comme pour Mix :

```sh
export POSTGRES_PORT=5433
docker compose up -d
mix setup
```

Les variables d'environnement de production sont documentées dans `.env.example` (aucun fichier `.env` n'est nécessaire en développement).

## Qualité

La barre de qualité est appliquée en local et en CI par la même commande :

```sh
mix precommit
```

Elle enchaîne, dans cet ordre : compilation avec warnings bloquants (`compile --warnings-as-errors`), vérification du formatage (`format --check-formatted`), analyse statique ([Credo](https://hexdocs.pm/credo/) en mode strict), analyse de sécurité ([Sobelow](https://hexdocs.pm/sobelow/)), puis les tests. Elle doit passer avant chaque commit.

Commandes complémentaires :

```sh
mix coveralls        # couverture de tests, échoue sous le seuil de 90 %
mix coveralls.html   # rapport de couverture détaillé dans cover/excoveralls.html
mix deps.audit       # audit des vulnérabilités des dépendances
```

Le seuil de couverture (90 % minimum, voir `coveralls.json`) et l'audit des dépendances sont appliqués à chaque push par la CI GitHub Actions (`.github/workflows/ci.yml`), qui rejoue exactement `mix precommit` : aucune divergence entre le local et la CI.

## Sources de données

- [Wikidata](https://www.wikidata.org/) (CC0) : événements, dates, coordonnées, relations
- [Wikipedia](https://www.wikipedia.org/) (CC BY-SA 4.0) : résumés et liens vers les articles
- [Cliopatria / Seshat](https://github.com/Seshat-Global-History-Databank/cliopatria) (CC BY 4.0) : frontières historiques

## Licence

[AGPL-3.0](LICENSE)

## Historique

Ce dépôt a hébergé un prototype Django + React (2020-2022), conservé dans l'historique git. Un ancien site statique sans rapport avec le projet est archivé dans `docs/archive/2022-site-html/`.
