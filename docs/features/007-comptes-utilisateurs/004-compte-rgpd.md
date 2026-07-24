# Issue #033 -- Page compte, export et suppression RGPD

**Feature :** F07 -- Comptes utilisateurs
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #032

---

## Contexte

L'authentification est complète (#030 à #032) ; il reste à donner à l'utilisateur la maîtrise de ses données, engagement fondateur du projet (ADR 0008, `.claude/rules/ethics.md` : "données contributeurs minimales, export complet, suppression réelle"). Cette issue livre la page compte et les deux droits RGPD exercables en autonomie, sans email au support ni délai : l'export (portabilité, article 20) et la suppression (effacement, article 17).

La page compte est volontairement minimale, à l'image des données : l'email, la date de création, les sessions actives avec révocation. Pas de profil, pas d'avatar, pas de préférences : rien de tout cela n'existe en base et rien ne doit être ajouté ici.

Deux exigences non négociables de la vue d'ensemble F07 :

- **Suppression RÉELLE** : hard delete de la ligne `accounts.users`, cascade sur les tokens (FK `on_delete: :delete_all` posée en #032, tokens magic link purgés par email), aucune colonne `deleted_at`, aucune rétention cachée. Après suppression, l'email peut recréer un compte vierge comme s'il n'était jamais venu.
- **Export réel** : un JSON téléchargeable contenant TOUT ce que la base sait du compte. Aujourd'hui c'est court (compte + métadonnées de sessions) ; le format doit être conçu pour s'étendre en F08 (contributions, révisions) sans casser : structure versionnée, une clé par contexte.

Cette issue introduit la première route du `live_session :require_authenticated_user` (hook écrit et testé en #032) et met la politique de confidentialité en cohérence : `/confidentialite` promet aujourd'hui "un unique cookie technique" anonyme ; il faut y décrire les comptes (données collectées, finalité, durée, cookie de session authentifiée, droits et comment les exercer). Une politique de confidentialité fausse est une vitre cassée légale.

Impact sur le reste du système : routes `/compte` et `/compte/export` (pipeline authentifié), page `/confidentialite` amendée, aucun changement des parcours anonymes.

## User Story

> En tant qu'utilisateur connecté, je veux voir ce que le service sait de moi, télécharger ces données, révoquer mes sessions et supprimer définitivement mon compte, afin d'exercer mes droits sans dépendre de personne.

---

## Tâches

- [ ] Fonctions de façade `Amanogawa.Accounts` :
  - `list_session_tokens/1` (sessions actives d'un utilisateur : `inserted_at` et un indicateur "session courante" déterminé côté web par comparaison du token, jamais en exposant les hash).
  - `revoke_session_token/2` (révocation d'UNE session par id, vérifiant l'appartenance à l'utilisateur : IDOR check, `.claude/rules/security.md`, permission vérifiée avant CHAQUE mutation).
  - `export_user_data/1` : map sérialisable versionnée `%{format_version: 1, exported_at: ..., account: %{email, inserted_at}, sessions: [%{inserted_at}]}` ; moduledoc notant que F08 ajoutera une clé `contributions`. Jamais de hash de token dans l'export.
  - `delete_user/1` : transaction supprimant les magic link tokens de l'email puis la ligne user (les session tokens partent par cascade FK) ; retourne `:ok`. Hard delete, aucun soft delete.
- [ ] `AmanogawaWeb.AccountLive` (`lib/amanogawa_web/live/account_live.ex`) sur `/compte`, première route du `live_session :require_authenticated_user` (routeur : scope avec `pipe_through :browser` + `plug :require_authenticated_user` équivalent conn pour les routes non-live du même scope) :
  - Affiche email et date de création (format localisé fr/en via Gettext).
  - Liste les sessions actives (date d'ouverture, badge "session courante") avec bouton de révocation par session et bouton "révoquer toutes les autres sessions" ; la révocation de la session courante équivaut à une déconnexion.
  - Lien de téléchargement de l'export (`/compte/export`).
  - Zone de suppression : bouton ouvrant une confirmation explicite (saisie du mot "SUPPRIMER" ou de l'email, au choix d'implémentation, mais une confirmation en deux temps est requise), texte annonçant l'irréversibilité. La suppression déconnecte et redirige vers `/` avec un flash neutre de confirmation.
  - Pas de requête dans `mount/3` : chargement dans `handle_params/3` (règle LiveView), collections via streams si listées.
- [ ] `AmanogawaWeb.AccountController` (`lib/amanogawa_web/controllers/account_controller.ex`) : `export/2` sur GET `/compte/export`, derrière le plug d'authentification conn (`AmanogawaWeb.UserAuth.require_authenticated_user` version plug, ajoutée en #032 ou ici si manquante) : répond `application/json` avec `content-disposition: attachment; filename="amanogawa-export-<date>.json"`, corps `Jason.encode!` de `export_user_data/1`. Aucun cache (`cache-control: no-store` : donnée personnelle).
- [ ] Révocation effective immédiate : après révocation d'une session (ou suppression du compte), diffuser le `disconnect` sur le live_socket_id concerné (mécanique posée en #032) pour que les onglets ouverts de cette session repassent anonymes sans attendre une navigation.
- [ ] Politique de confidentialité (`lib/amanogawa_web/controllers/page_html/privacy.html.heex`, fr/en via Gettext) : nouvelle section "Comptes utilisateurs" : données collectées (email, uniquement), finalité (authentification, attribution des futures contributions), base légale, durée (jusqu'à suppression par l'utilisateur ; tokens de connexion 15 minutes, sessions 60 jours), cookie de session authentifiée (HttpOnly, SameSite=Lax, Secure) en complément du cookie technique anonyme déjà décrit, emails envoyés (magic link seul, aucune newsletter), droits (export et suppression en autonomie depuis `/compte`, contact pour le reste). Reformuler la section existante pour que "aucun cookie" reste exact pour le visiteur anonyme et que le cas connecté soit décrit honnêtement.
- [ ] Vérifier que la page `/confidentialite` reste servie par le pipeline `:static_page` sans cookie (test existant intact) : la mise à jour est purement rédactionnelle.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `export_user_data/1` contient `format_version`, l'email, `inserted_at` et une entrée par session active ; aucun `token_hash` ni token clair n'apparaît dans la map (assertion récursive).
- [ ] **Happy path** : `delete_user/1` supprime user, session tokens (cascade) et magic link tokens de l'email ; les tables sont vides pour cet utilisateur.
- [ ] **Edge case** : suppression puis re-demande de magic link avec le même email : nouveau compte vierge, `inserted_at` récent, aucune trace de l'ancien.
- [ ] **Error case** : `revoke_session_token/2` avec l'id d'une session d'un AUTRE utilisateur : refus (`{:error, :not_found}` ou équivalent), la session tierce survit (anti-IDOR).
- [ ] **Limit case** : `list_session_tokens/1` n'inclut pas les sessions expirées (plus vieilles que 60 jours) : liste vide plutôt que sessions fantômes.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout utilisateur généré avec un nombre arbitraire de sessions, `Jason.encode!(export_user_data(user))` réussit toujours et le décodage restitue une entrée par session active (l'export est un sérialiseur : il ne doit jamais lever).

### Doctests (si applicable)

- [ ] Non applicable : toutes les fonctions de l'issue touchent la base.

### Tests d'intégration

- [ ] **Intégration (LiveViewTest, AccountLive)** : connecté (helper `register_and_log_in_user/1` de #032), `/compte` affiche email, date et sessions ; anonyme, `/compte` redirige vers `/connexion` (hook `:require_authenticated_user`).
- [ ] **Intégration (LiveViewTest, révocation)** : révoquer une autre session la fait disparaître de la liste et son token ne résout plus en base ; révoquer la session courante déconnecte et redirige.
- [ ] **Intégration (LiveViewTest, suppression)** : le parcours de confirmation en deux temps aboutit à la suppression réelle en base, à la déconnexion et à la redirection ; une confirmation erronée ne supprime rien.
- [ ] **Intégration (ConnCase, export)** : connecté, GET `/compte/export` répond 200, `application/json`, `content-disposition` en pièce jointe, `cache-control: no-store`, corps décodable contenant l'email ; anonyme, redirection vers `/connexion` (jamais de fuite de données sans session).
- [ ] **Intégration (ConnCase, confidentialité)** : `/confidentialite` mentionne la section comptes dans les deux locales et ne dépose toujours aucun cookie (étendre le test existant du pipeline `:static_page` plutôt que le dupliquer).

### Tests end-to-end (si applicable)

- [ ] **E2E (Wallaby)** : prolonger le parcours de `test/e2e/auth_journey_test.exs` (#032) ou créer `account_journey_test.exs` : connexion par magic link, ouverture de `/compte`, vérification de l'email affiché, téléchargement de l'export non vérifiable en headless : à la place, vérifier la présence du lien ; puis suppression du compte avec confirmation, retour à l'état anonyme, carte fonctionnelle, et impossibilité de se reconnecter avec l'ancienne session.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/accounts.ex` (export, suppression, sessions)
  - `lib/amanogawa_web/live/account_live.ex`
  - `lib/amanogawa_web/controllers/account_controller.ex`
  - `lib/amanogawa_web/router.ex` (scope authentifié : `live_session :require_authenticated_user` + route conn `/compte/export`)
  - `lib/amanogawa_web/user_auth.ex` (plug conn `require_authenticated_user` si non posé en #032)
  - `lib/amanogawa_web/controllers/page_html/privacy.html.heex`
  - `test/amanogawa/accounts_test.exs` (extension), `test/amanogawa_web/live/account_live_test.exs`, `test/amanogawa_web/controllers/account_controller_test.exs`, `test/amanogawa_web/controllers/page_controller_test.exs` (extension), `test/e2e/account_journey_test.exs`
  - `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : ADR 0008 et `.claude/rules/ethics.md` (export complet, suppression réelle), `.claude/rules/security.md` (IDOR : vérifier l'appartenance avant chaque mutation), vue d'ensemble F07 et F08 (`docs/features/008-editeur-collaboratif/000-editeur-collaboratif.md` : l'export s'étendra aux contributions, l'attribution des révisions publiques survivra différemment à la suppression du compte, à arbitrer en F08 dans un ADR), articles 17 et 20 du RGPD (cnil.fr).
- **Compétences requises** : LiveView (streams, confirmations), sérialisation JSON, RGPD opérationnel, rédaction fr/en de contenu légal.
- **Points d'attention** :
  - La suppression du compte en F07 est totale et sans ambiguïté car l'utilisateur n'a encore AUCUNE contribution ; F08 devra arbitrer (ADR dédié) le devenir de l'attribution des révisions publiques après suppression (pseudonymisation à la Wikipedia) : concevoir `delete_user/1` comme le point unique où ce futur arbitrage s'insérera, et le noter dans son moduledoc.
  - Ne jamais exposer les hash de tokens, ni dans l'export, ni dans la liste des sessions (ids opaques seulement).
  - La confirmation de suppression doit résister au double clic et à la soumission concurrente (la seconde tentative trouve un compte déjà absent : répondre proprement, pas de 500).
  - L'export est une réponse authentifiée à ne jamais mettre en cache ni logger en corps.
  - Rester sobre sur la page compte : aucune statistique d'usage, aucun historique de connexion au-delà des sessions actives (en collecter plus serait contraire à la minimisation affichée).
  - Les textes fr restent la référence, l'anglais suit (politique de langue CLAUDE.md).
