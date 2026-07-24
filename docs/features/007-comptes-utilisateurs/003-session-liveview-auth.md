# Issue #032 -- Session serveur, scope courant et parcours de connexion LiveView

**Feature :** F07 -- Comptes utilisateurs
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #031

---

## Contexte

Le domaine sait générer, envoyer et vérifier des magic links (#030, #031). Cette issue construit toute la surface web de l'authentification : l'échange du lien contre une session, la matérialisation de l'utilisateur courant dans les conns et les LiveViews, et le parcours utilisateur de bout en bout (formulaire, page d'attente, déconnexion).

Arbitrages non négociables de la vue d'ensemble F07, appliqués ici :

- **Session en base, révocable côté serveur.** Le cookie ne porte qu'un token opaque ; la ligne `accounts.session_tokens` correspondante peut être supprimée à tout moment (déconnexion, révocation depuis la page compte en #033, suppression du compte). Un cookie signé seul ne serait pas révocable.
- **`@current_scope.user`**, jamais `@current_user` : convention scope de Phoenix 1.8 (`Amanogawa.Accounts.Scope`), qui accueillera les rôles de modération de F08 sans casser les signatures.
- **`live_session :current_user`** pour les routes publiques (scope assigné, `user` pouvant être `nil`) et **`live_session :require_authenticated_user`** pour les routes authentifiées ; jamais deux `live_session` du même nom dans le routeur.
- **La lecture reste 100 % publique.** `ExploreLive` et les pages statiques fonctionnent sans compte, à l'identique : AUCUNE régression, les tests existants (LiveViewTest, ConnCase, suite E2E Wallaby) doivent rester verts sans modification de leurs assertions. Le pipeline `:static_page` reste sans session : la promesse "aucun cookie sur les pages d'information" de `/confidentialite` reste vraie.

Point de sécurité structurant : les scanners d'emails (antivirus, préchargement des clients mail) suivent les liens par GET. Un token à usage unique consommé par GET serait donc brûlé avant que l'utilisateur ne clique. Le GET du lien magic n'exécute RIEN : il affiche une page de confirmation dont le bouton soumet le token en POST (protégé CSRF) ; seule la soumission POST consomme le token et crée la session. C'est le même dispositif que phx.gen.auth.

Impact sur le reste du système : le pipeline `:browser` gagne un plug `fetch_current_scope_for_user`, la route `live "/", ExploreLive` est enveloppée dans `live_session :current_user`, le layout racine gagne un lien discret connexion/compte. Les endpoints JSON `/api` et `/health` ne changent pas.

## User Story

> En tant que visiteur, je veux demander un lien de connexion depuis un formulaire, cliquer sur le lien reçu et me retrouver connecté (puis pouvoir me déconnecter), afin d'accéder à mon compte sans mot de passe, pendant que l'exploration de la carte reste possible sans aucun compte.

---

## Tâches

- [ ] Migration `create_accounts_session_tokens` : table `accounts.session_tokens` : `id` `binary_id`, `user_id` référence `accounts.users` avec `on_delete: :delete_all` (FK interne au schéma `accounts`, autorisée par `.claude/rules/architecture.md`), `token_hash` `binary` non nul unique, `inserted_at` non nul. Index sur `user_id`.
- [ ] Schéma `Amanogawa.Accounts.SessionToken` (`lib/amanogawa/accounts/session_token.ex`) et fonctions de façade : `create_session_token/1` (retourne le token clair, hash seul en base : même discipline que #030), `get_user_by_session_token/1` (valide 60 jours, fenêtre appliquée en requête), `delete_session_token/1`, `renew_session_token/1` (si le token présenté a plus de 7 jours, en émettre un nouveau et supprimer l'ancien dans la même transaction : expiration glissante sans réémission à chaque requête). Étendre la purge Oban de #030 aux session tokens expirés.
- [ ] Scope : `Amanogawa.Accounts.Scope` (`lib/amanogawa/accounts/scope.ex`), struct `%Scope{user: %User{} | nil}` avec `for_user/1` ; c'est la valeur assignée à `@current_scope` partout (conn et sockets).
- [ ] Module `AmanogawaWeb.UserAuth` (`lib/amanogawa_web/user_auth.ex`), unique lieu de la plomberie session :
  - `log_in_user(conn, user)` : `configure_session(renew: true)` (anti-fixation), stocke le token de session en session Plug (cookie signé existant `_amanogawa_key`, HttpOnly par défaut, `SameSite=Lax` déjà configuré dans l'endpoint), redirige vers la page d'origine ou `/`.
  - `log_out_user(conn)` : supprime le token en base, `configure_session(renew: true)` + drop, redirige vers `/`.
  - Plug `fetch_current_scope_for_user` : lit le token de session, résout l'utilisateur (une requête), assigne `@current_scope` (`Scope.for_user(user)` ou `Scope.for_user(nil)`), déclenche `renew_session_token/1` le cas échéant. Toujours assigner un scope, jamais `nil` nu.
  - `on_mount` : `:mount_current_scope` (assigne `@current_scope` depuis la session du socket, user possiblement `nil`) et `:require_authenticated_user` (redirige vers `/connexion` avec flash si non connecté et stocke le chemin de retour). Pas de requête DB dans `mount/3` des LiveViews : la résolution se fait dans le `on_mount` (autorisé, c'est le pattern phx.gen.auth) avec UNE seule requête.
- [ ] Routeur (`lib/amanogawa_web/router.ex`) :
  - `plug :fetch_current_scope_for_user` ajouté au pipeline `:browser` (après `:fetch_session`). Les pipelines `:static_page`, `:api`, `:health` ne changent pas.
  - `live_session :current_user, on_mount: [{AmanogawaWeb.UserAuth, :mount_current_scope}]` enveloppant `live "/", ExploreLive` et `live "/connexion", LoginLive`.
  - Routes contrôleur : `get "/connexion/:token"` (page de confirmation), `post "/connexion/:token"` (échange), `delete "/deconnexion"`.
  - Le `live_session :require_authenticated_user` (avec `on_mount: [{AmanogawaWeb.UserAuth, :require_authenticated_user}]`) est introduit ici avec sa première route en #033 (`/compte`) ; le hook est écrit et testé dès cette issue. Ne JAMAIS dupliquer un nom de `live_session`.
- [ ] `AmanogawaWeb.SessionController` (`lib/amanogawa_web/controllers/session_controller.ex`) :
  - `confirm/2` (GET) : affiche la page de confirmation avec bouton POST portant le token ; ne touche pas au token en base (protection contre les scanners d'emails, voir Contexte). Page traduite fr/en (SetLocale est déjà dans `:browser`).
  - `create/2` (POST) : `Accounts.redeem_magic_link_token/1` ; succès -> `log_in_user/2` avec flash de bienvenue ; échec -> redirection vers `/connexion` avec flash neutre "lien invalide ou expiré, demandez-en un nouveau" (même message pour token inconnu, expiré, déjà utilisé : pas d'oracle).
  - `delete/2` (DELETE) : `log_out_user/1`.
- [ ] `AmanogawaWeb.LoginLive` (`lib/amanogawa_web/live/login_live.ex`) : formulaire email unique (pas de distinction inscription/connexion : le flux est le même, décision #030). À la soumission : récupérer l'IP du peer (`get_connect_info/2` `:peer_data`, même mécanique que le limiteur de sélection d'`ExploreLive`), appeler `Accounts.deliver_magic_link/3` avec une `url_fun` construite sur `url(~p"/connexion/#{token}")` en propageant la locale courante en paramètre `locale` (le plug `SetLocale` la résoudra au clic). Afficher ensuite l'état "vérifiez votre boîte mail" : MÊME état rendu que l'email soit connu ou inconnu (anti-énumération) ; `{:error, :rate_limited}` affiche "trop de demandes, réessayez dans quelques minutes" ; `{:error, changeset}` réaffiche le formulaire avec l'erreur de format. Si l'utilisateur est déjà connecté, rediriger vers `/`.
- [ ] Layout racine ou en-tête d'`ExploreLive` : lien sobre "Connexion" (scope user `nil`) ou email + bouton "Déconnexion" (connecté), sans bouleverser l'UI de la carte ; textes via Gettext.
- [ ] Cookie `Secure` : activer `force_ssl: [hsts: true]` dans la config prod de l'endpoint (le commentaire de `config/runtime.exs` le prévoit déjà) OU l'option `secure: true` des options de session en prod ; trancher, documenter dans `docs/ops/deploy.md` (kamal-proxy termine le TLS : vérifier le header `x-forwarded-proto` avec `TRUSTED_PROXIES`). Le cookie de session authentifiée ne doit jamais transiter en clair en production.
- [ ] Vérification de non-régression explicite : `mix test` ET `mix test.e2e` passent sans modifier les tests existants d'`ExploreLive`, des pages statiques et des API ; la page `/confidentialite` ne dépose toujours aucun cookie (test existant du pipeline `:static_page`).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `create_session_token/1` + `get_user_by_session_token/1` restituent l'utilisateur ; seul le hash est en base.
- [ ] **Happy path** : `delete_session_token/1` : le token ne résout plus rien (révocation serveur immédiate).
- [ ] **Edge case** : `renew_session_token/1` sur un token de plus de 7 jours retourne un nouveau token et invalide l'ancien ; sur un token récent, ne change rien.
- [ ] **Error case** : token de session altéré, vide ou inconnu : `get_user_by_session_token/1` retourne `nil` sans lever.
- [ ] **Limit case** : token de 60 jours moins une seconde accepté, plus vieux refusé (piloter `inserted_at`, pas de sleep).

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout binaire arbitraire distinct d'un token de session émis, `get_user_by_session_token/1` retourne `nil` (jamais d'exception, jamais de session volée par malformation).

### Doctests (si applicable)

- [ ] Non applicable : toute la surface de l'issue dépend de conns, sockets ou de la base.

### Tests d'intégration

- [ ] **Intégration (ConnCase, SessionController)** : GET `/connexion/:token` avec un token valide affiche la confirmation SANS consommer le token (il reste échangeable) ; POST l'échange, pose la session, redirige ; un second POST du même token redirige avec le flash neutre (usage unique).
- [ ] **Intégration (ConnCase, plug)** : avec session posée, `@current_scope.user` est l'utilisateur ; sans session, `@current_scope.user` est `nil` (jamais d'assign absent) ; après DELETE `/deconnexion`, la session ne résout plus et le token est supprimé en base.
- [ ] **Intégration (ConnCase, sécurité)** : le cookie de session ne contient pas le token en clair déchiffrable côté client au-delà de la signature Phoenix ; `configure_session(renew: true)` régénère l'identifiant de session au login (anti-fixation, comparer les cookies avant/après).
- [ ] **Intégration (LiveViewTest, LoginLive)** : soumission d'un email valide affiche "vérifiez votre boîte" et un email part (`Swoosh.TestAssertions` via l'adaptateur réel, ou mock Mox selon la config de test de #031) ; email inconnu : rendu strictement identique ; email invalide : erreur de formulaire ; rate limited (quota de test abaissé via la config runtime du throttle) : message dédié ; utilisateur connecté : redirection.
- [ ] **Intégration (LiveViewTest, scope)** : `ExploreLive` monte et fonctionne avec `@current_scope.user == nil` (parcours anonyme intact) ET avec un utilisateur connecté (`log_in_user` helper de `ConnCase`) ; le hook `:require_authenticated_user` redirige un socket anonyme vers `/connexion` avec retour post-login.
- [ ] **Intégration (helpers)** : ajouter `register_and_log_in_user/1` et `log_in_user/2` à `test/support/conn_case.ex` (pattern phx.gen.auth) pour #033 et F08.

### Tests end-to-end (si applicable)

- [ ] **E2E (Wallaby)** : parcours complet dans `test/e2e/auth_journey_test.exs` : ouvrir `/connexion`, soumettre un email, lire l'email dans la boîte de test (configurer `Swoosh.Adapters.Test` en mode partagé depuis le setup E2E, `Application.put_env(:swoosh, :shared_test_process, self())`, même mécanique d'env test-only que `FeatureCase.start_wallaby_and_raise_test_only_rate_limits/0` ; `mix test.e2e` est un BEAM séparé, pas de fuite vers `mix test`), extraire l'URL du corps, la visiter, confirmer (bouton POST), vérifier l'état connecté sur `/`, se déconnecter, vérifier le retour à l'état anonyme avec la carte toujours fonctionnelle.
- [ ] **E2E (non-régression)** : la suite E2E existante (`explore_journey_test.exs` et consorts) passe inchangée.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `priv/repo/migrations/<timestamp>_create_accounts_session_tokens.exs`
  - `lib/amanogawa/accounts/session_token.ex`, `lib/amanogawa/accounts/scope.ex`, `lib/amanogawa/accounts.ex` (fonctions session), `lib/amanogawa/accounts/workers/purge_expired_tokens.ex` (extension)
  - `lib/amanogawa_web/user_auth.ex`
  - `lib/amanogawa_web/controllers/session_controller.ex` + `session_html.ex` + `session_html/confirm.html.heex`
  - `lib/amanogawa_web/live/login_live.ex`
  - `lib/amanogawa_web/router.ex`, layout racine ou en-tête (lien connexion/déconnexion)
  - `config/prod.exs` ou endpoint (cookie Secure/force_ssl), `docs/ops/deploy.md`
  - `test/support/conn_case.ex` (helpers), `test/amanogawa_web/user_auth_test.exs`, `test/amanogawa_web/controllers/session_controller_test.exs`, `test/amanogawa_web/live/login_live_test.exs`, `test/e2e/auth_journey_test.exs`, extension de `test/amanogawa/accounts_test.exs`
  - `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : phx.gen.auth Phoenix 1.8 (scopes, magic link, page de confirmation anti-prefetch) comme référence de conception, à transposer sans exécuter le générateur ; `lib/amanogawa_web/live/explore_live.ex` (lecture du `peer_data`), `test/support/feature_case.ex` (mécanique d'env test-only du BEAM E2E), `lib/amanogawa_web/plugs/set_locale.ex` (propagation de la locale par paramètre), vue d'ensemble F07 (arbitrages), OWASP Session Management Cheat Sheet.
- **Compétences requises** : Plug.Session et cycle de vie des cookies, LiveView (`on_mount`, `live_session`, `get_connect_info`), Wallaby, sécurité des sessions (fixation, révocation).
- **Points d'attention** :
  - La consommation du token magic DOIT être dans le POST, jamais dans le GET : c'est la seule défense contre les scanners de liens des clients mail.
  - `configure_session(renew: true)` au login ET au logout : anti-fixation dans les deux sens.
  - Le `live_session :current_user` change la manière dont les tests LiveView existants montent `ExploreLive` : le plug du pipeline `:browser` assigne le scope même pour un GET anonyme, donc `live(conn, "/")` continue de fonctionner sans setup supplémentaire ; si un test existant casse, c'est un signal de régression à corriger côté code, pas côté test.
  - Ne pas mettre l'utilisateur complet en session Plug (seulement le token opaque) : la session est un cookie signé lisible par le client.
  - La déconnexion doit aussi déconnecter les LiveViews en cours : `log_out_user` diffuse `disconnect` sur le live_socket_id (pattern phx.gen.auth) pour tuer les sockets du token révoqué.
  - Budget requêtes : le plug fait UNE requête par navigation HTML pour résoudre le scope ; aucune résolution supplémentaire dans les LiveViews (le scope arrive par le `on_mount`).
  - Les routes `/api` restent sans session ni scope : la carte anonyme n'embarque aucun coût nouveau.
