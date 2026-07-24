# F07 -- Comptes utilisateurs

> Phase 2 | Priorité P0 (phase 2) | Estimation : 1 semaine (40h) | Statut : en cours

## Résumé

Authentification magic link sans mot de passe (patterns shuyuan) : email -> token 15 min -> session en base (révocation server-side), rate limiting Hammer, schéma PG `accounts`. Données minimales (email seul), export et suppression RGPD réels.

Prérequis à l'éditeur collaboratif (F08), qui consommera `@current_scope.user` pour attribuer les contributions et étendra l'export RGPD aux révisions.

## Points déjà arbitrés

- Pas de mot de passe, pas d'OAuth tiers (pas de dépendance à Google/GitHub pour un projet souverain).
- `@current_scope.user`, `live_session :require_authenticated_user` / `:current_user`, jamais de duplication de noms de live_session.
- Aucun compte requis pour explorer (la lecture reste 100 % publique).

## Arbitrages du découpage

- Le token magic link est lié à un email, pas à un utilisateur : le compte est créé (ou retrouvé) à la première vérification réussie. L'email est vérifié par construction et le flux est identique pour un email connu ou inconnu (anti-énumération structurelle, #030).
- Token clair jamais persisté (hash SHA-256 seul en base), usage unique consommé en transaction, invalidation des tokens précédents du même email, purge Oban quotidienne (#030).
- Le GET du lien magic n'exécute rien (page de confirmation, échange en POST) : protection contre les scanners d'emails qui préchargent les liens (#032).
- Sessions en base (`accounts.session_tokens`, 60 jours, renouvellement glissant), cookie signé HttpOnly SameSite=Lax Secure ne portant qu'un token opaque, révocation individuelle depuis la page compte (#032, #033).
- Réutilisation de l'existant, pas de nouvelle infrastructure : `Amanogawa.Mailer` (Swoosh + gen_smtp, relais SMTP local, issue #028), `AmanogawaWeb.RateLimit` (Hammer ETS unique, clés préfixées dédiées), `SetLocale`/Gettext fr-en, patterns de façade d'`Amanogawa.Atlas`.
- Suppression de compte : hard delete, aucune rétention ; le devenir de l'attribution des contributions après suppression sera arbitré en F08 (ADR dédié), sans contribution en F07 la question ne se pose pas encore.

## Analyse

### Architecture

- Quatrième bounded context `Accounts` : schéma PG `accounts` (users, magic_link_tokens, session_tokens), façade `Amanogawa.Accounts`, aucune écriture croisée avec les autres contextes.
- Frontière hexagonale pour l'envoi d'email : behaviour `MagicLinkNotifier` + adaptateur Swoosh, mock Mox en test (même pattern que `Alerting.Notifier`).
- Web : `AmanogawaWeb.UserAuth` (plug `fetch_current_scope_for_user`, hooks `on_mount`), `SessionController` (échange du lien, déconnexion), `LoginLive`, `AccountLive`.

### Sécurité

- Tokens crypto forts (`:crypto.strong_rand_bytes/1`), hash seuls en base, comparaison non oraculaire, fenêtres de validité appliquées en requête.
- Rate limiting 5 demandes / 15 min par IP ET par email (compteurs distincts) ; réponses indistinguables email connu/inconnu.
- Anti-fixation (`configure_session(renew: true)` au login et au logout), révocation server-side immédiate (disconnect des sockets), anti-IDOR sur la révocation de sessions.

### Éthique (ADR 0008)

- Données minimales : email et date de création, rien d'autre ; email texte brut sans ressource distante ; aucun tracking.
- Export JSON complet et suppression réelle exercables en autonomie depuis `/compte` ; politique de confidentialité mise à jour honnêtement (cookie de session authentifiée décrit, pages statiques toujours sans cookie).

### Performance

- Une seule requête de résolution du scope par navigation ; aucun coût nouveau sur les parcours anonymes (`/api`, `/health`, pages statiques inchangés).

## User Stories

- GIVEN un visiteur anonyme sur `/connexion`, WHEN il soumet son email, THEN il voit "vérifiez votre boîte" (que l'email ait un compte ou non) et reçoit un lien valable 15 minutes à usage unique.
- GIVEN un lien magic reçu, WHEN l'utilisateur le visite puis confirme, THEN une session révocable est créée et il revient connecté sur la carte ; un second usage du lien échoue avec un message neutre.
- GIVEN un utilisateur connecté sur `/compte`, WHEN il exporte ses données, THEN il télécharge un JSON contenant tout ce que la base sait de lui.
- GIVEN un utilisateur connecté, WHEN il supprime son compte après confirmation, THEN toutes ses données sont réellement effacées et la carte reste explorable anonymement.
- GIVEN un visiteur sans compte, WHEN il explore carte et frise, THEN rien n'a changé : aucune authentification requise, aucune régression.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #030 Contexte Accounts : schéma PG, utilisateurs et tokens magic link | 001-contexte-accounts-magic-link.md | 12h |
| #031 Envoi de l'email magic link, rate limiting et anti-énumération | 002-envoi-magic-link-rate-limite.md | 8h |
| #032 Session serveur, scope courant et parcours de connexion LiveView | 003-session-liveview-auth.md | 12h |
| #033 Page compte, export et suppression RGPD | 004-compte-rgpd.md | 8h |

## Dépendances

- Prérequis : F01 (#001) ; réutilise l'infrastructure SMTP et alerting de F06 (#028) et le limiteur Hammer de F03 (#014).
- Chaîne interne : #030 -> #031 -> #032 -> #033 (strictement séquentielle : chaque issue consomme l'API de la précédente).
- Sortie : fondation de F08 (éditeur collaboratif), qui attribuera les contributions à `@current_scope.user` et étendra l'export RGPD.
