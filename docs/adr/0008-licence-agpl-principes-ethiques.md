# 0008. Publier sous AGPL-3.0 avec des principes éthiques non négociables

Date : 2026-07-23
Statut : Accepté

## Contexte

Amanogawa s'appuie entièrement sur des communs (Wikidata CC0, Wikipedia CC BY-SA, Cliopatria CC BY, historical-basemaps GPL) et vise à terme un éditeur collaboratif ouvert "à la Wikipedia" avec une algorithmie sociale éthique. Le projet doit rendre aux communs ce qu'il leur prend, et se protéger d'une réutilisation fermée en SaaS. Les autres projets de l'auteur (shuyuan) suivent déjà ce modèle.

## Décision

Nous allons publier le code sous AGPL-3.0, en dépôt public, avec les principes suivants inscrits comme contraintes (règle `.claude/rules/ethics.md`) : zéro tracking tiers, CSP stricte, étiquette Wikimedia respectée (User-Agent identifié, cache, backoff), attribution systématique des sources (page Sources dédiée), et pour la phase collaborative : historique de révisions public, pas de ranking par engagement, modération transparente, données contributeurs minimales et exportables (RGPD).

## Conséquences

Positives :
- Compatibilité de licence avec toutes les sources retenues ; l'AGPL force le partage des améliorations, y compris en usage service.
- La confiance est un actif pour attirer des contributeurs à l'éditeur de phase 2.

Négatives :
- L'AGPL peut dissuader certaines réutilisations commerciales ; assumé, c'est l'effet recherché.
- Zéro tracking prive de métriques fines d'usage ; accepté, des métriques serveur agrégées suffisent.

## Alternatives considérées

**MIT/Apache-2.0.** Adoption maximale mais permet l'appropriation fermée d'un projet construit sur des communs ; rejeté.

**Développement privé puis ouverture.** Retarde la confiance et complique l'hygiène du dépôt (secrets, historique) ; rejeté, le dépôt était déjà public.
