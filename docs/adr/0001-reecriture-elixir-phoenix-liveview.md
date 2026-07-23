# 0001. Réécrire le projet en Elixir / Phoenix LiveView

Date : 2026-07-23
Statut : Accepté

## Contexte

Amanogawa a existé sous forme de prototype Django + Django REST Framework + React-Leaflet (2020-2022) : modèles Event (PointField) et Country (MultiPolygonField) via GeoDjango, API filtrable par années, slider temporel. Le prototype est sans tests, avec les relations entre événements laissées en commentaire, une base SQLite commitée et un front React que nous ne souhaitons plus maintenir (préférence explicite : pas de framework front JS/TS, Tailwind, animations soignées).

Depuis, tous les projets récents de l'auteur (shuyuan, Seigneurie, corbacs-du-nord, domus, site photo) sont en Elixir / Phoenix LiveView, avec un outillage commun (Credo, Sobelow, StreamData, Oban, Kamal 2 sur Hetzner) et des conventions partagées.

Le projet exige : interactivité riche carte + frise (fenêtre temporelle glissante, gradients, animations), ingestion massive de données externes (Wikidata ~420 000 événements, Wikipedia, frontières historiques), et à terme un éditeur collaboratif temps réel.

## Décision

Nous allons réécrire Amanogawa de zéro en Elixir / Phoenix 1.8 avec LiveView, en abandonnant le code du prototype Django/React (conservé dans l'historique git).

## Conséquences

Positives :
- Cohérence totale avec l'écosystème de projets existant : outillage, règles, déploiement, compétences réutilisées.
- LiveView permet l'interactivité exigée sans framework front ; les bibliothèques de rendu (MapLibre, d3) s'intègrent en hooks JS vanilla.
- OTP + Oban conviennent parfaitement aux pipelines d'ingestion longs et idempotents ; PubSub prépare l'édition collaborative de la phase 2.

Négatives :
- L'écosystème géospatial Elixir (geo_postgis) est moins riche que GeoDjango ; accepté car la logique géo lourde vit dans PostGIS lui-même et le rendu est côté client.
- Aucune réutilisation du code 2020-2022 ; accepté car ce code était un prototype jetable.

## Alternatives considérées

**Reprendre Django + GeoDjango.** GeoDjango est mature et le prototype existait, mais le code n'apportait aucun acquis réel (pas de tests, fonctionnalités incomplètes), il aurait fallu choisir un front (retour de React refusé, htmx moins bien maîtrisé), et la cohérence avec les autres projets aurait été perdue.

**Django backend + LiveView-like (htmx).** Cumule les inconvénients : deux écosystèmes à maintenir, pas de temps réel natif pour la phase collaborative.
