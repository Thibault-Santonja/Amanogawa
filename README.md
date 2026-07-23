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
- [Node.js](https://nodejs.org/) avec npm (dépendances front installées dans `assets/` par `mix setup`)

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

Elle enchaîne, dans cet ordre : compilation avec warnings bloquants (`compile --warnings-as-errors`), vérification du formatage (`format --check-formatted`), analyse statique ([Credo](https://hexdocs.pm/credo/) en mode strict), analyse de sécurité ([Sobelow](https://hexdocs.pm/sobelow/)), build des assets (`assets.build`), puis les tests. Elle doit passer avant chaque commit.

Commandes complémentaires :

```sh
mix coveralls        # couverture de tests, échoue sous le seuil de 90 %
mix coveralls.html   # rapport de couverture détaillé dans cover/excoveralls.html
mix deps.audit       # audit des vulnérabilités des dépendances
```

Le seuil de couverture (90 % minimum, voir `coveralls.json`) et l'audit des dépendances sont appliqués à chaque push par la CI GitHub Actions (`.github/workflows/ci.yml`), qui rejoue exactement `mix precommit` : aucune divergence entre le local et la CI.

## Fond de carte

Le fond de tuiles vectorielles est servi par [OpenFreeMap](https://openfreemap.org/), instance publique communautaire distribuant les tuiles OpenMapTiles de la planète : gratuit, sans clé API, sans cookie ni suivi des utilisateurs, projet lui-même open source. Décision prise dans l'issue [#005](docs/features/001-fondations/005-fond-de-carte-maphook.md) face à l'alternative Protomaps/PMTiles auto-hébergée : qualité visuelle supérieure, coût nul et aucune infrastructure supplémentaire au stade du MVP. Le risque de dépendance à un service sans SLA est mitigé par le vendoring des styles (voir ci-dessous) et par une bascule possible vers PMTiles.

### Styles vendorés

Les styles MapLibre sont dans le dépôt (`assets/vendor/map-styles/light.json` et `dark.json`) et embarqués dans le bundle JS : seuls les tuiles, les glyphes et les sprites sont récupérés sur `https://tiles.openfreemap.org` (seule origine distante autorisée par la Content-Security-Policy). Origine et licences, le format JSON n'admettant pas de commentaire d'en-tête :

- récupérés le 23 juillet 2026 depuis `https://tiles.openfreemap.org/styles/positron` (clair) et `https://tiles.openfreemap.org/styles/dark` (sombre) ;
- dérivés des styles OpenMapTiles [Positron](https://github.com/openmaptiles/positron-gl-style) et [Dark Matter](https://github.com/openmaptiles/dark-matter-gl-style) (code BSD-3-Clause, design CC-BY 4.0) ;
- modifications locales : champ `name` et attribution ajoutés, aucune autre altération ;
- un test (`test/amanogawa_web/map_styles_test.exs`) garantit la structure des styles, la cohérence de leurs URLs avec la CSP et la présence de l'attribution.

### Attribution

Les données des tuiles sont sous licence [ODbL](https://www.openstreetmap.org/copyright) : l'attribution `© OpenStreetMap contributors` est obligatoire et ne doit jamais disparaître de la carte (elle est déclarée dans les styles vendorés et affichée par le contrôle d'attribution MapLibre). OpenFreeMap est crédité par courtoisie.

### Bascule future vers PMTiles auto-hébergé

Si l'exigence d'auto-hébergement complet ou la disponibilité d'OpenFreeMap le justifie (décision prévue au plus tard en F06, déploiement) :

1. générer ou télécharger un build planétaire PMTiles (Protomaps) et le servir depuis notre infrastructure (fichier statique + range requests) ;
2. repointer `sources`, `glyphs` et `sprite` des deux styles vendorés vers la nouvelle origine (et adapter les couches si le schéma de tuiles diffère du schéma OpenMapTiles) ;
3. remplacer l'origine des tuiles dans `AmanogawaWeb.Plugs.ContentSecurityPolicy` ;
4. le hook `MapHook` est agnostique du fournisseur et reste inchangé.

### Budget JS

Constaté après build minifié (`mix assets.deploy`) : `app.js` complet à environ 322 KB gzip (1,2 MB brut), dont MapLibre GL JS (environ 230 KB gzip attendus), les deux styles vendorés et le socle Phoenix/LiveView. Aucune autre dépendance front n'est installée à ce stade (d3 arrive avec la frise).

## Sources de données

- [Wikidata](https://www.wikidata.org/) (CC0) : événements, dates, coordonnées, relations
- [Wikipedia](https://www.wikipedia.org/) (CC BY-SA 4.0) : résumés et liens vers les articles
- [Cliopatria / Seshat](https://github.com/Seshat-Global-History-Databank/cliopatria) (CC BY 4.0) : frontières historiques

## Licence

[AGPL-3.0](LICENSE)

## Historique

Ce dépôt a hébergé un prototype Django + React (2020-2022), conservé dans l'historique git. Un ancien site statique sans rapport avec le projet est archivé dans `docs/archive/2022-site-html/`.
