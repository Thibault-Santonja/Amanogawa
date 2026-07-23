# F08 -- Éditeur collaboratif éthique

> Phase 2 | Priorité P0 (phase 2) | Estimation : 4-6 semaines | Statut : à spécifier

## Résumé

Ouvrir la contribution "à la Wikipedia" : proposer un événement, corriger une date ou une localisation, ajouter une relation ou une source, avec un historique de révisions public et une modération transparente. Algorithmie sociale éthique : pas de ranking par engagement, pas de gamification addictive, files de relecture chronologiques.

Le découpage en issues sera fait à l'ouverture de la phase 2. Ce document fixe les principes pour que les choix de phase 1 ne les compromettent pas.

## Principes directeurs (fondés sur ADR 0008)

- **Données en couches** : les données issues de Wikidata restent traçables et resynchronisables ; les contributions locales vivent en surcouche (jamais d'écrasement silencieux d'une source par une édition, ni l'inverse). Le schéma `contributions` (edits, revisions, reviews) est séparé d'`atlas`.
- **Transparence** : chaque révision est publique, datée, attribuée ; les règles de modération sont publiées ; les décisions sont journalisées et appelables.
- **Anti-dark-patterns** : pas de compteurs de likes, pas de streaks, pas de notifications d'engagement ; la reconnaissance passe par l'historique des contributions.
- **Redistribution** : étudier la remontée des améliorations factuelles vers Wikidata (boucle vertueuse avec le commun d'origine).

## Implications pour la phase 1

- Les QID restent la clé d'identité des événements (surcouche possible).
- `location_source` et la provenance des dates sont déjà tracés (une édition humaine devient une provenance supplémentaire).
- Les gabarits de validation/permission des endpoints (F03) doivent être pensés pour accueillir des mutations en phase 2.
