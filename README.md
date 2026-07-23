# Amanogawa (天の川)

Rendre l'histoire visible : une carte du monde et une frise chronologique interactives pour explorer les événements historiques, de la préhistoire à aujourd'hui.

Les événements sont issus de Wikidata et Wikipedia : chaque événement est placé sur la carte (point ou zone), positionné sur la frise, relié aux événements qui lui sont liés, et renvoie vers son article Wikipedia. Les zones d'influence des entités politiques s'affichent en fond de carte selon la période sélectionnée.

## Statut

Projet en phase de cadrage. Voir `docs/roadmap.md` pour le plan et `docs/adr/` pour les décisions d'architecture.

## Stack

- Elixir / Phoenix LiveView
- PostgreSQL + PostGIS
- Tailwind CSS, MapLibre GL JS (hook LiveView)

## Sources de données

- [Wikidata](https://www.wikidata.org/) (CC0) : événements, dates, coordonnées, relations
- [Wikipedia](https://www.wikipedia.org/) (CC BY-SA 4.0) : résumés et liens vers les articles
- [Cliopatria / Seshat](https://github.com/Seshat-Global-History-Databank/cliopatria) (CC BY 4.0) : frontières historiques

## Licence

[AGPL-3.0](LICENSE)

## Historique

Ce dépôt a hébergé un prototype Django + React (2020-2022), conservé dans l'historique git. Un ancien site statique sans rapport avec le projet est archivé dans `docs/archive/2022-site-html/`.
