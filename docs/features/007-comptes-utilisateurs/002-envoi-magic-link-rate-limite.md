# Issue #031 -- Envoi de l'email magic link, rate limiting et anti-énumération

**Feature :** F07 -- Comptes utilisateurs
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #030

---

## Contexte

Le contexte Accounts (#030) sait générer et vérifier des tokens ; il faut maintenant faire parvenir le lien à l'utilisateur. Cette issue couvre l'envoi de l'email et les protections d'abus, toujours sans surface web : la LiveView de demande arrive en #032. Elle réutilise l'infrastructure existante au lieu d'en créer une nouvelle :

- **Swoosh + gen_smtp** sont déjà en dépendances et configurés depuis l'issue #028 : `Amanogawa.Mailer` (relais SMTP local du VPS en prod, `Swoosh.Adapters.Local` en dev, `Swoosh.Adapters.Test` en test, `config/runtime.exs` et `config/test.exs`). Aucune dépendance ni configuration d'adaptateur à ajouter.
- **Hammer** est déjà en place : `AmanogawaWeb.RateLimit` est le limiteur ETS unique du projet (démarré par `Amanogawa.Application`), utilisé par `AmanogawaWeb.Plugs.RateLimit` pour les endpoints JSON et par `ExploreLive` pour la sélection d'événements. Le rate limiting du magic link frappe le même limiteur avec des clés dédiées, il ne crée pas de second Hammer.

Le pattern d'architecture suit `Amanogawa.Alerting.Notifier` / `Amanogawa.Alerting.Notifier.Mailer` : un behaviour défini côté domaine, un adaptateur de production Swoosh à côté, un mock Mox en test (`.claude/rules/architecture.md`, frontières hexagonales). L'email est en texte brut uniquement (comme l'alerting : sobre, lisible partout, aucun tracking pixel possible), traduit fr/en via Gettext.

Deux propriétés de sécurité structurent l'issue :

- **Anti-énumération.** Grâce au choix de #030 (compte créé à la vérification, token lié à l'email), un email inconnu reçoit un lien exactement comme un email connu : il n'existe AUCUNE branche "email inconnu" dans le flux. Le contrat de la façade doit préserver cela : aucune valeur de retour, aucun délai mesurable, aucun message ne doit révéler si un compte existe.
- **Rate limiting double.** 5 demandes par fenêtre de 15 minutes PAR IP et, indépendamment, PAR EMAIL normalisé : la limite IP borne le spam d'un client, la limite email empêche de bombarder la boîte d'un tiers depuis plusieurs IP. Deux clés Hammer distinctes, deux compteurs.

Impact sur le reste du système : le moduledoc de `Amanogawa.Mailer` (qui affirme n'avoir que l'alerting comme appelant et "no user-facing email in phase 1") devient faux et doit être mis à jour dans cette issue (Boyscout Rule). `.env.example` doit refléter que le relais SMTP sert désormais aussi les emails utilisateurs.

## User Story

> En tant que visiteur souhaitant me connecter, je veux recevoir par email un lien de connexion à usage unique dans ma langue, afin d'accéder à mon compte sans mot de passe, sans qu'un tiers puisse ni inonder ma boîte ni découvrir si mon adresse a un compte.

---

## Tâches

- [ ] Behaviour `Amanogawa.Accounts.MagicLinkNotifier` (`lib/amanogawa/accounts/magic_link_notifier.ex`) : `@callback deliver(email :: String.t(), magic_link_url :: String.t(), locale :: String.t()) :: :ok | {:error, term()}`. Le domaine ne connaît ni Swoosh ni SMTP (aucun concern de transport ne traverse l'adaptateur, règle hexagonale).
- [ ] Adaptateur `Amanogawa.Accounts.MagicLinkNotifier.Mailer` (`lib/amanogawa/accounts/magic_link_notifier/mailer.ex`), sur le modèle exact de `Amanogawa.Alerting.Notifier.Mailer` : construit l'email Swoosh (`text_body` uniquement, pas de HTML), expéditeur lu en config à l'appel (réutiliser `ALERT_FROM_EMAIL` via une config `:amanogawa, Amanogawa.Accounts` avec repli documenté, plutôt qu'inventer une deuxième adresse d'expédition), délivre via `Amanogawa.Mailer.deliver/1`, mappe le résultat sur `:ok` / `{:error, reason}`.
- [ ] Contenu de l'email via Gettext (`AmanogawaWeb.Gettext` est le backend existant, locales `fr`/`en` déjà connues) : sujet et corps traduits, corps contenant l'URL du lien, la durée de validité (15 minutes), la mention "usage unique" et une phrase "si vous n'êtes pas à l'origine de cette demande, ignorez cet email". La locale est un PARAMÈTRE du deliver (posée avec `Gettext.with_locale/3` autour du rendu) : ne pas dépendre de la locale du process appelant, l'envoi pouvant être asynchrone.
- [ ] Module `Amanogawa.Accounts.MagicLinkThrottle` (`lib/amanogawa/accounts/magic_link_throttle.ex`) : `allow?(ip, email)` frappe `AmanogawaWeb.RateLimit.hit/3` deux fois avec des clés à préfixes distincts (`"magic_link:ip:" <> ip` et `"magic_link:email:" <> email_normalisé`), quota et fenêtre lus à l'appel dans `config :amanogawa, Amanogawa.Accounts.MagicLinkThrottle` (défaut `limit: 5`, `scale_ms: :timer.minutes(15)`), même mécanique runtime-configurable que `AmanogawaWeb.Plugs.RateLimit`. Les deux compteurs sont frappés dans un ordre fixe et le refus de l'un vaut refus global. Note de couche : le module vit dans le contexte Accounts mais s'appuie sur le limiteur partagé `AmanogawaWeb.RateLimit` ; documenter dans le moduledoc que c'est un choix assumé (un seul Hammer ETS dans l'application) déjà pratiqué par `ExploreLive`.
- [ ] Orchestration dans la façade `Amanogawa.Accounts` : `deliver_magic_link(email, ip, magic_link_url_fun)` où `magic_link_url_fun` est une fonction `(clear_token -> url)` fournie par l'appelant web (le domaine ne connaît pas le routeur, même inversion que phx.gen.auth). Enchaîne : normalisation + validation email, throttle, génération du token (#030), appel du notifier configuré (`Application.get_env`, mock Mox en test). Retours : `:ok` (email parti ou email inconnu, indistinguables par construction), `{:error, :rate_limited}`, `{:error, changeset}` (email syntaxiquement invalide : pas un secret, le formulaire peut l'afficher).
- [ ] Mettre à jour le moduledoc de `Amanogawa.Mailer` (l'alerting n'est plus le seul appelant, il existe désormais un email utilisateur) : Boyscout Rule sur une affirmation devenue fausse.
- [ ] `.env.example` : amender le commentaire du bloc SMTP (issue #028) pour mentionner que le relais sert aussi les emails de connexion magic link ; ajouter la variable d'expéditeur si une variable dédiée distincte de `ALERT_FROM_EMAIL` est retenue, avec défaut documenté. `config/runtime.exs` : câbler la config correspondante (quota du throttle surchargeable via `MAGIC_LINK_RATE_LIMIT` optionnelle, même esprit que `RATE_LIMIT_PER_MINUTE`).
- [ ] Enregistrer le mock dans `test/support/mocks.ex` (`Mox.defmock(Amanogawa.MagicLinkNotifierMock, for: Amanogawa.Accounts.MagicLinkNotifier)`) et configurer `config/test.exs` pour l'utiliser par défaut ; l'adaptateur Swoosh réel est testé séparément avec `Swoosh.Adapters.Test`.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `deliver_magic_link/3` avec un email valide retourne `:ok` et le mock du notifier reçoit exactement un appel avec une URL contenant le token clair généré et la locale demandée.
- [ ] **Happy path (adaptateur)** : `MagicLinkNotifier.Mailer.deliver/3` envoie via `Swoosh.Adapters.Test` un email texte brut au bon destinataire, sujet et corps en français pour `"fr"`, en anglais pour `"en"` (`import Swoosh.TestAssertions`, `assert_email_sent`) ; AUCUN envoi réel possible en test (adaptateur Test déjà configuré par `config/test.exs`, à vérifier par assertion).
- [ ] **Edge case (anti-énumération)** : email avec compte existant et email sans compte : mêmes valeurs de retour, même nombre d'appels au notifier, aucun champ de la réponse ne diffère.
- [ ] **Error case** : le notifier retourne `{:error, :smtp_down}` : la façade ne lève pas et ne divulgue pas la nature de l'erreur au-delà d'un tuple taggué loggable ; le token généré reste en base (l'utilisateur peut redemander, l'invalidation des précédents fait le ménage).
- [ ] **Error case** : email syntaxiquement invalide : `{:error, changeset}`, aucun token créé, aucun appel au notifier, aucun compteur de throttle consommé pour l'email (le compteur IP peut l'être : choix à documenter dans le moduledoc du throttle).
- [ ] **Limit case (throttle IP)** : 5 demandes depuis la même IP passent, la 6e retourne `{:error, :rate_limited}` sans appel au notifier ni token créé.
- [ ] **Limit case (throttle email)** : 5 demandes pour le même email (casse variable) depuis des IP différentes passent, la 6e est refusée : la clé email est bien normalisée et indépendante de la clé IP.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout email valide généré, l'URL passée au notifier contient un token qui, passé à `redeem_magic_link_token/1`, authentifie ce même email normalisé (composition #030 + #031 sans perte).

### Doctests (si applicable)

- [ ] Non applicable : toutes les fonctions publiques de l'issue dépendent de la base, du limiteur ETS ou du notifier ; aucun exemple pur pertinent.

### Tests d'intégration

- [ ] **Intégration** : chaîne complète avec l'adaptateur Swoosh réel (pas le mock) : `deliver_magic_link/3` aboutit à un email capturé par `Swoosh.Adapters.Test` dont l'URL extraite du corps permet un `redeem_magic_link_token/1` réussi.
- [ ] **Intégration (throttle)** : les quotas magic link et le quota des endpoints JSON (`AmanogawaWeb.Plugs.RateLimit`) sont indépendants : épuiser l'un ne consomme pas l'autre (préfixes de clés distincts sur le même Hammer).

### Tests end-to-end (si applicable)

- [ ] Non applicable : pas de surface web dans cette issue ; le parcours complet boîte de réception incluse est le scénario E2E de #032.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/accounts/magic_link_notifier.ex` (behaviour)
  - `lib/amanogawa/accounts/magic_link_notifier/mailer.ex` (adaptateur Swoosh)
  - `lib/amanogawa/accounts/magic_link_throttle.ex`
  - `lib/amanogawa/accounts.ex` (fonction `deliver_magic_link/3`)
  - `lib/amanogawa/mailer.ex` (moduledoc, Boyscout)
  - `config/config.exs` (notifier par défaut, quota par défaut du throttle), `config/test.exs` (mock), `config/runtime.exs` (expéditeur, quota surchargeable), `.env.example`
  - `test/support/mocks.ex`
  - `test/amanogawa/accounts/magic_link_notifier/mailer_test.exs`, `test/amanogawa/accounts/magic_link_throttle_test.exs`, extension de `test/amanogawa/accounts_test.exs`
  - `priv/gettext/*/LC_MESSAGES/*.po` (nouvelles chaînes, `mix gettext.extract --merge`)
- **Documentation de référence** : `lib/amanogawa/alerting/notifier/mailer.ex` (pattern behaviour + adaptateur Swoosh à répliquer), `lib/amanogawa_web/plugs/rate_limit.ex` et `lib/amanogawa_web/rate_limit.ex` (mécanique Hammer et config runtime), `.claude/rules/security.md` (rate limiting), issue #028 (infrastructure SMTP), documentation Swoosh (`Swoosh.TestAssertions`).
- **Compétences requises** : Swoosh, Gettext (`with_locale/3`), Hammer, Mox, conception d'API anti-oracle.
- **Points d'attention** :
  - Ne JAMAIS logger l'URL du lien ni le token clair, y compris en cas d'échec SMTP : logger l'email peut se discuter (donnée personnelle : préférer un hash tronqué ou rien), l'URL jamais.
  - L'IP reçue par `deliver_magic_link/3` sera, côté web (#032), l'IP corrigée par `RemoteIp` (endpoint) ou le `peer_data` LiveView : le throttle se contente d'une chaîne, il ne résout rien lui-même.
  - Le texte de l'email ne contient AUCUNE ressource distante (pas d'image, pas de lien autre que le magic link) : cohérence zéro tracking (ADR 0008).
  - `Swoosh.Adapters.Local` en dev expose la boîte à `/dev/mailbox` (route dev de Phoenix) : vérifier qu'elle est bien accessible en dev pour le confort de test manuel, sans rien exposer hors `:dev`.
  - Fenêtre fixe Hammer (comme l'existant) : un léger effet de bord de fenêtre est acceptable pour ce cas d'usage ; ne pas introduire d'algorithme de limitation supplémentaire.
