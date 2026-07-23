# F07 -- Comptes utilisateurs

> Phase 2 | Priorité P0 (phase 2) | Estimation : 1 semaine | Statut : à spécifier

## Résumé

Authentification magic link sans mot de passe (patterns shuyuan) : email -> token 15 min -> session en base (révocation server-side), rate limiting Hammer, schéma PG `accounts`. Données minimales (email seul), export et suppression RGPD réels.

Prérequis à l'éditeur collaboratif (F08). Le découpage en issues sera fait à l'ouverture de la phase 2, après le bilan du MVP.

## Points déjà arbitrés

- Pas de mot de passe, pas d'OAuth tiers (pas de dépendance à Google/GitHub pour un projet souverain).
- `@current_scope.user`, `live_session :require_authenticated_user` / `:current_user`, jamais de duplication de noms de live_session.
- Aucun compte requis pour explorer (la lecture reste 100 % publique).
