# Issue #030 -- Contexte Accounts : schéma PG, utilisateurs et tokens magic link

**Feature :** F07 -- Comptes utilisateurs
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #001

---

## Contexte

La phase 2 introduit les comptes utilisateurs, prérequis de l'éditeur collaboratif (F08). Le point d'entrée est le contexte `Accounts`, quatrième bounded context annoncé depuis F01 (`.claude/rules/architecture.md`, `.claude/memory/domain-model.md`) : son schéma PostgreSQL dédié `accounts`, sa façade publique `Amanogawa.Accounts`, et le coeur du mécanisme d'authentification arbitré pour le projet : le magic link sans mot de passe (aucun mot de passe stocké, jamais ; pas d'OAuth tiers, décision de la vue d'ensemble F07).

Cette issue pose uniquement la couche domaine : schémas Ecto, génération et vérification de tokens, purge. Aucun email n'est envoyé (issue #031), aucune route ni session web n'existe encore (issue #032). Cette séparation permet de tester exhaustivement la cryptographie et les invariants du cycle de vie des tokens en `DataCase` pur, sans dépendance web ni SMTP.

Décisions de conception portées par cette issue :

- **Le token magic link est lié à un email, pas à un utilisateur.** Le compte est créé (ou retrouvé) au moment de la vérification réussie du lien, jamais à la demande. Conséquences : l'email est vérifié par construction avant toute création de compte, une demande pour un email inconnu se comporte exactement comme pour un email connu (anti-énumération, exploitée en #031), et aucune ligne `users` n'est créée pour une faute de frappe ou un spam de formulaire.
- **Le token clair ne touche jamais la base.** Seul son hash SHA-256 est stocké ; une fuite de base ne donne aucun lien de connexion utilisable.
- **Usage unique et fenêtre courte.** Un token est valide 15 minutes, consommé (supprimé) à la première vérification réussie, et toute nouvelle demande pour un email invalide les tokens précédents de cet email.

Impact sur le reste du système : nouvelle migration (schéma `accounts` + deux tables), nouvelle queue Oban `accounts` avec un cron de purge quotidien, aucune modification des contextes existants. Le modèle de données reste minimal conformément à l'ADR 0008 : un utilisateur est un email et une date de création, rien d'autre.

## User Story

> En tant que futur contributeur, je veux qu'un compte se résume à mon adresse email vérifiée par un lien à usage unique et à durée courte, afin de pouvoir m'authentifier sans mot de passe et sans confier plus de données que nécessaire.

---

## Tâches

- [ ] Migration `create_accounts_schema_and_tables` sur le modèle de `20260723090000_create_postgis_and_schemas.exs` (le schéma PG arrive avec son contexte) :
  - `CREATE SCHEMA IF NOT EXISTS accounts` dans `up`, `DROP SCHEMA` dans `down` (pas de suppression d'extension partagée).
  - Table `accounts.users` : `id` `binary_id` (UUID v7, même convention que `atlas.events`), `email` `string` non nul, `inserted_at` `utc_datetime` non nul. Pas d'autre colonne : données minimales (ADR 0008). Index unique sur `email`.
  - Table `accounts.magic_link_tokens` : `id` `binary_id`, `email` non nul, `token_hash` `binary` non nul, `inserted_at` non nul. Index unique sur `token_hash`, index sur `email` (invalidation par email), index sur `inserted_at` (purge).
- [ ] Unicité d'email insensible à la casse : normaliser l'email en minuscules dans le changeset (trim + downcase) plutôt que d'ajouter l'extension `citext` (une extension de moins à maintenir ; `citext` reste l'alternative documentée si un besoin de casse préservée apparaissait). L'index unique porte donc sur la valeur normalisée, et TOUTE entrée d'email du contexte (création, recherche, génération de token) passe par la même fonction de normalisation.
- [ ] Schéma `Amanogawa.Accounts.User` (`lib/amanogawa/accounts/user.ex`) : `@schema_prefix "accounts"`, `@primary_key {:id, UUIDv7, autogenerate: true}` (même mécanisme que les schémas Atlas), changeset avec normalisation, validation de format d'email (présence d'un `@`, pas d'espace, longueur bornée à 160 comme phx.gen.auth, sans regex sur-restrictive), `unique_constraint`.
- [ ] Schéma `Amanogawa.Accounts.MagicLinkToken` (`lib/amanogawa/accounts/magic_link_token.ex`) : `@schema_prefix "accounts"`, champs `email`, `token_hash`, `inserted_at`.
- [ ] Module interne `Amanogawa.Accounts.MagicLink` (`lib/amanogawa/accounts/magic_link.ex`) portant la cryptographie et les requêtes :
  - Génération : `:crypto.strong_rand_bytes(32)` encodé `Base.url_encode64(padding: false)` (token clair retourné à l'appelant, jamais persisté), hash `:crypto.hash(:sha256, token)` persisté.
  - `create/1` : dans une transaction, supprime les tokens existants de l'email normalisé (invalidation des précédents) puis insère le nouveau ; retourne `{clear_token, %MagicLinkToken{}}`.
  - `verify/1` : décode le token clair reçu, recalcule le hash, cherche le token non expiré (fenêtre `@validity_minutes 15` appliquée en requête sur `inserted_at`, pas de colonne d'expiration), et le CONSOMME dans la même transaction (delete) : usage unique garanti même en cas de double clic concurrent (le second `delete` ne trouve plus de ligne). Retourne `{:ok, email}` ou `:error`, sans distinguer token inconnu, expiré ou déjà consommé (aucun oracle).
  - Comparaison à temps constant : la recherche se fait par égalité sur le hash SHA-256 (l'index unique sert la recherche ; le hash rend l'égalité SQL non exploitable en timing car l'attaquant ne contrôle pas la valeur comparée). Tout endroit du code qui comparerait deux binaires de token en Elixir utilise `Plug.Crypto.secure_compare/2`.
- [ ] Façade `Amanogawa.Accounts` (`lib/amanogawa/accounts.ex`), sur le modèle de `Amanogawa.Atlas` (fonctions fines déléguant aux modules internes, seul module appelable hors du contexte) :
  - `generate_magic_link_token/1` (email -> `{:ok, {clear_token, token}}` ou `{:error, changeset}` si email invalide).
  - `redeem_magic_link_token/1` (token clair -> `{:ok, %User{}}` ou `:error`) : vérifie via `MagicLink.verify/1` puis `get-or-create` de l'utilisateur par email normalisé dans la même transaction (upsert `on_conflict: :nothing` + relecture, pour rester idempotent en concurrence).
  - `get_user!/1`, `get_user_by_email/1`.
  - `purge_expired_magic_link_tokens/0` : supprime les tokens plus vieux que la fenêtre de validité, retourne le nombre supprimé.
- [ ] Worker Oban `Amanogawa.Accounts.Workers.PurgeExpiredTokens` (`lib/amanogawa/accounts/workers/purge_expired_tokens.ex`) : queue `accounts`, délègue à la façade. Ajouter la queue `accounts: 1` et l'entrée cron quotidienne (heure creuse, par exemple `"30 3 * * *"`) dans `config/config.exs`, à côté du cron d'ingestion existant (le cron est déjà désactivé en test par `config/test.exs`, rien à faire de ce côté).
- [ ] Documenter dans le moduledoc de la façade les invariants de sécurité (hash seul en base, usage unique, 15 minutes, invalidation des précédents, création du compte à la vérification) pour que #031 et #032 s'appuient dessus sans les réinventer.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `generate_magic_link_token/1` puis `redeem_magic_link_token/1` avec le token clair retourné crée l'utilisateur (email normalisé), retourne `{:ok, user}`, et la table `magic_link_tokens` ne contient plus le token (consommé).
- [ ] **Happy path** : `redeem_magic_link_token/1` pour un email ayant DÉJÀ un compte retourne le compte existant sans en créer un second.
- [ ] **Edge case** : deux `generate_magic_link_token/1` successifs pour le même email : seul le second token est vérifiable, le premier retourne `:error` (invalidation des précédents) ; les casses différentes du même email (`User@X` / `user@x`) partagent la même invalidation et le même compte.
- [ ] **Edge case** : le token clair n'apparaît nulle part en base : la colonne `token_hash` ne contient pas la valeur retournée à l'appelant (assertion explicite).
- [ ] **Error case** : token altéré (un caractère changé), token vide, binaire non décodable en Base64 url-safe, token bien formé mais inconnu : tous retournent `:error` sans lever, et la réponse est la même dans les quatre cas.
- [ ] **Error case** : email invalide (`sans-arobase`, chaîne vide, > 160 caractères) : `generate_magic_link_token/1` retourne `{:error, changeset}` et n'insère rien.
- [ ] **Limit case** : token de 15 minutes moins une seconde accepté, 15 minutes plus une seconde refusé (piloter `inserted_at` en base plutôt que d'attendre : pas de `Process.sleep`, `.claude/rules/testing.md`).
- [ ] **Limit case** : deux consommations concurrentes du même token (deux tâches simultanées) : exactement une réussit.
- [ ] **Purge** : `purge_expired_magic_link_tokens/0` supprime les tokens expirés, préserve les valides, retourne le compte exact.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout email valide généré, le cycle générer -> vérifier retourne l'email normalisé ; la normalisation est idempotente (`normalize(normalize(e)) == normalize(e)`).
- [ ] **Property** : pour tout binaire arbitraire distinct du token clair émis, `redeem_magic_link_token/1` retourne `:error` (jamais d'exception, jamais de succès) : le vérificateur est un point d'entrée de données hostiles, comme les parsers SPARQL.

### Doctests (si applicable)

- [ ] **Doctest** : normalisation d'email dans le moduledoc de `User` (fonction pure, exemple parlant : trim + downcase).

### Tests d'intégration

- [ ] **Intégration** (DataCase) : le worker `PurgeExpiredTokens` exécuté via `perform_job/2` (Oban.Testing, déjà importé par `Amanogawa.DataCase`) purge réellement en base et retourne `:ok`.
- [ ] **Intégration** : la migration monte ET descend proprement (`mix ecto.rollback` sur la migration) ; le schéma `accounts` existe après migration.

### Tests end-to-end (si applicable)

- [ ] Non applicable : aucune surface web dans cette issue ; le parcours complet est couvert par le scénario E2E de #032.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `priv/repo/migrations/<timestamp>_create_accounts_schema_and_tables.exs`
  - `lib/amanogawa/accounts.ex` (façade)
  - `lib/amanogawa/accounts/user.ex`
  - `lib/amanogawa/accounts/magic_link_token.ex`
  - `lib/amanogawa/accounts/magic_link.ex`
  - `lib/amanogawa/accounts/workers/purge_expired_tokens.ex`
  - `config/config.exs` (queue `accounts`, cron de purge)
  - `test/amanogawa/accounts_test.exs`, `test/amanogawa/accounts/workers/purge_expired_tokens_test.exs`
  - `test/support/accounts_fixtures.ex` (builder canonique `user_fixture/1`, même style que `AtlasFixtures`)
- **Documentation de référence** : vue d'ensemble F07 (points arbitrés), ADR 0008 (données minimales), `.claude/rules/architecture.md` (façade, `@schema_prefix`), `.claude/rules/testing.md` (property tests, pas de sleep), `.claude/memory/domain-model.md` ; le générateur `phx.gen.auth` de Phoenix 1.8 en mode magic link est la référence de conception (hash en base, validité en requête), à adapter à la main : ne pas exécuter le générateur, qui produirait mots de passe optionnels, `users_tokens` polyvalente et vues inutiles ici.
- **Compétences requises** : Ecto (migrations multi-schémas, transactions, upsert), primitives crypto Erlang (`:crypto.strong_rand_bytes`, `:crypto.hash`), Oban (worker + cron), StreamData.
- **Points d'attention** :
  - Le token clair ne doit JAMAIS être loggué ni inspecté (attention aux `Logger.debug` et aux messages d'erreur de changeset) ; `MagicLinkToken` peut redéfinir `Inspect` pour masquer `token_hash`, comme phx.gen.auth le fait pour les mots de passe.
  - `inserted_at` en `utc_datetime` partout ; pas de `updated_at` sur les tokens (immuables, consommés ou purgés).
  - La fenêtre de validité est une constante de module documentée, pas une config : 15 minutes est un arbitrage de sécurité de la vue d'ensemble F07, pas un réglage d'exploitation.
  - Aucun appel `Amanogawa.Repo` hors du contexte : la façade est la seule porte (règle absolue AGENTS.md).
  - Le cron de purge est une hygiène, pas une sécurité : la sécurité vient de la fenêtre appliquée en requête dans `verify/1` ; un token expiré non purgé reste inutilisable.
