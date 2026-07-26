# F08 -- Éditeur collaboratif éthique

> Phase 2 | Priorité P0 (phase 2) | Estimation : 2 semaines (70h) | Statut : livrée

## Résumé

Ouvrir la contribution "à la Wikipedia" : corriger une date (avec sa précision), une position, un libellé, proposer un lien entre événements ou un événement nouveau, avec un historique de révisions public et une modération transparente. Toute contribution est une proposition sourcée, relue avant d'être visible sur la carte ; tout le processus (propositions, décisions, motifs, appels) est public sur un flux chronologique pur, sans aucun tri algorithmique.

F08 s'appuie sur F07 (comptes magic link, `@current_scope`, live_session `:require_authenticated_user`, pipeline `:authenticated`) et sur le modèle Atlas existant (`location_source` et provenance déjà tracés, upserts Wikidata par QID préservant des colonnes via `@wikidata_columns`).

## Principes directeurs (fondés sur ADR 0008)

- **Données en couches** : les données issues de Wikidata restent traçables et resynchronisables ; les contributions locales vivent en surcouche (jamais d'écrasement silencieux d'une source par une édition, ni l'inverse). Le schéma `contributions` (overrides, revisions, conflicts) est séparé d'`atlas`.
- **Transparence** : chaque révision est publique, datée, attribuée ; les règles de modération sont publiées ; les décisions sont journalisées et appelables.
- **Anti-dark-patterns** : pas de compteurs de likes, pas de streaks, pas de notifications d'engagement ; la reconnaissance passe par l'historique des contributions.
- **Redistribution** : étudier la remontée des améliorations factuelles vers Wikidata (boucle vertueuse avec le commun d'origine).

Les implications posées en phase 1 ont été honorées : les QID restent la clé d'identité des événements, `location_source` et la provenance des dates sont tracés (une édition humaine devient une provenance supplémentaire, valeur `:contribution`), les gabarits de validation et permission de F03/F07 accueillent les mutations.

## Décisions de cadrage (mainteneur)

- **Périmètre V1 de l'éditeur** : corrections d'événements EXISTANTS (dates avec précision, position, libellés, liens entre événements) et PROPOSITION de nouveaux événements. PAS d'édition des frontières : le dataset Cliopatria est externe et versionné, hors périmètre.
- **Modèle de données en couches** : table `contributions.overrides` (une ligne par champ corrigé par événement, avec valeur proposée, source ou justification OBLIGATOIRE (URL ou référence), statut) et `contributions.revisions` (historique append-only). La valeur affichée est l'override accepté, sinon la valeur Wikidata. La sync mensuelle ne touche JAMAIS un champ ayant un override accepté, mais journalise les divergences dans `contributions.conflicts` (table à examiner par les relecteurs).
- **Workflow de modération V1** : toute contribution est une proposition. Un rôle "relecteur" (colonne `role` sur `accounts.users`, promu manuellement en base pour commencer) accepte ou rejette avec motif public ; l'auteur peut répondre une fois (appel). Tout est public sur `/contributions` : flux chronologique PUR, aucun tri algorithmique.
- **Quotas anti-abus** : contributions rate-limitées par utilisateur ET par IP (limiteur Hammer existant, `AmanogawaWeb.RateLimit`, clés préfixées comme `Amanogawa.Accounts.MagicLinkThrottle`), taille des justifications bornée.

## Arbitrages du découpage

- **Mécanisme de résolution de la valeur affichée** : colonne résolue dans `atlas.events`, maintenue par le contexte Contributions via l'API publique d'Atlas. À l'acceptation d'un override, Contributions appelle `Amanogawa.Atlas.apply_field_override/3` qui écrit la valeur corrigée dans les colonnes existantes et marque le champ dans une nouvelle colonne `atlas.events.overridden_fields` (tableau de noms de champs métier). La valeur Wikidata d'origine est snapshotée dans l'override (`wikidata_value_at_acceptance`), donc rien n'est perdu et tout est réversible. Alternatives rejetées : la vue matérialisée (rafraîchissements à orchestrer, fenêtre de staleness, duplication de toute la table pour une fraction de lignes corrigées) et la jointure à la lecture (fait payer à LA requête critique du projet, viewport carte < 300 ms p95, un pivot cross-schéma sur une table en une-ligne-par-champ, pour un cas rare). Les écritures d'override sont rares, les lectures sont le chemin chaud : résoudre à l'écriture est le bon compromis. Décision structurante actée dans l'ADR 0009 (rédigé en #039).
- **Nouveaux événements** : un événement accepté d'origine communautaire entre dans `atlas.events` avec un identifiant public local `L<uuid hex>` dans la colonne `qid` (format étendu, jamais en collision avec `Q\d+`, donc jamais touché par la sync) et une colonne `origin` (`:wikidata` | `:contribution`). Les paramètres web (`AmanogawaWeb.Params.EventId`) acceptent les deux formats. Le rapprochement ultérieur avec un item Wikidata réel relève de la redistribution (V2).
- **Liens entre événements** : AJOUT uniquement en V1. Le retrait d'un lien erroné exigerait des tombstones résistant à la resync mensuelle des relations (`on_conflict: :nothing` réinsérerait le lien supprimé) : complexité reportée, notée comme extension.
- **Attribution publique sans fuite d'email** : les données Accounts restent minimales, mais l'attribution publique exige un nom : colonne `display_name` (pseudonyme public, unique, borné) sur `accounts.users`, exigée avant la première proposition, modifiable depuis `/compte`. L'email ne paraît jamais publiquement.
- **Suppression de compte** : les contributions sont anonymisées, pas supprimées (`author_id` et `actor_id` mis à nil, affichage "compte supprimé") ; l'historique public reste cohérent, comme sur un wiki. Arbitrage RGPD documenté en #038 (politique de confidentialité) et dans l'ADR 0009.
- **Frontières de contextes préservées** : Contributions n'écrit dans Atlas que par la façade `Amanogawa.Atlas` ; la composition cross-contexte (export RGPD, noms d'affichage) se fait dans la couche web via les façades ; aucune FK entre schémas PG de contextes différents (les overrides portent `event_qid` et `author_id` sans contrainte référentielle croisée, règle `.claude/rules/architecture.md`).

## Analyse

### Architecture

- Quatrième et dernier contexte activé : `Contributions` (schéma PG `contributions` : overrides, revisions, conflicts), façade `Amanogawa.Contributions`, aucune écriture directe hors contexte.
- Atlas gagne des points d'entrée publics ciblés : `apply_field_override/3`, `release_field_override/3`, `create_contributed_event/1` ; les liens acceptés passent par `upsert_event_links/1` existant.
- La sync mensuelle (`Amanogawa.Ingestion.Workers.ImportEvents`) préserve les colonnes marquées dans `overridden_fields` (remplacement conditionnel par colonne dans l'upsert) et signale le lot à `Amanogawa.Contributions.record_sync_divergences/1` pour la journalisation des conflits.
- Web : extension d'`AmanogawaWeb.Components.EventPanel` (entrée d'édition, historique par événement), composant de formulaire de proposition dans `ExploreLive`, LiveViews `/relecture` et `/relecture/conflits` (live_session `:require_reviewer`), pages publiques `/contributions` et `/moderation`.

### Sécurité

- Permission vérifiée avant CHAQUE mutation (`.claude/rules/security.md`) : proposition = utilisateur authentifié ; décision et résolution de conflit = rôle relecteur, revérifié côté domaine (jamais seulement dans le routeur) ; appel = auteur de l'override uniquement (anti-IDOR).
- Toute valeur proposée est validée serveur avec les invariants du domaine (`Amanogawa.HistoricalDate.changeset/2`, Point SRID 4326 borné au monde, longueurs bornées) ; les identifiants clients sont recherchés, jamais interprétés.
- Quotas Hammer par IP et par utilisateur avant toute écriture ; justifications bornées ; motifs de décision bornés.

### Éthique (ADR 0008)

- Historique intégralement public, daté, attribué (pseudonyme) ; règles de modération publiées sur `/moderation` avec statistiques agrégées factuelles (aucun classement de contributeurs).
- Flux `/contributions` strictement chronologique, filtres factuels seulement (statut, événement) ; aucune notification d'engagement : un email sobre à la décision et à l'issue d'appel, rien d'autre.
- Export RGPD étendu aux contributions ; anonymisation à la suppression documentée honnêtement dans la politique de confidentialité.
- Redistribution : chaque override accepté conserve sa source (URL ou référence), matière première d'une future remontée vers Wikidata (V2, hors périmètre, étudiée dans l'ADR 0009).

### Performance

- Aucun coût nouveau sur le chemin de lecture chaud : la requête viewport et l'histogramme lisent `atlas.events` inchangé (valeurs déjà résolues).
- La détection de divergences ajoute une requête indexée par lot de sync (500 QID), négligeable devant les upserts.
- Pages publiques paginées (keyset), collections en streams LiveView.

## User Stories

- GIVEN un utilisateur connecté devant le panneau d'un événement, WHEN il propose une correction de date avec sa précision et une source, THEN la proposition apparaît "en attente" dans l'historique public et la valeur affichée sur la carte reste inchangée.
- GIVEN un relecteur devant la file de relecture, WHEN il accepte une proposition avec un motif, THEN la valeur affichée devient la valeur corrigée, la décision et son motif sont publics, et l'auteur reçoit un unique email sobre.
- GIVEN un auteur dont la proposition est rejetée, WHEN il répond une fois (appel), THEN sa réponse est publique et le relecteur re-décide ; une seconde réponse est impossible.
- GIVEN la sync mensuelle, WHEN Wikidata modifie un champ sous override accepté, THEN le champ affiché ne bouge pas et une divergence est journalisée dans les conflits, examinables par un relecteur.
- GIVEN un visiteur anonyme, WHEN il ouvre `/contributions` ou `/moderation`, THEN il voit le flux chronologique pur, les règles publiées et les décisions motivées, sans compte ni cookie supplémentaire.
- GIVEN un contributeur qui supprime son compte, WHEN la suppression est confirmée, THEN ses données personnelles sont effacées, ses contributions sont anonymisées ("compte supprimé") et l'historique public reste cohérent.

## Issues

| Issue | Fichier | Estimation |
|-------|---------|------------|
| #034 Contexte Contributions : surcouche, révisions et résolution | 001-contexte-contributions-surcouche.md | 14h |
| #035 Coexistence avec la sync mensuelle et examen des divergences | 002-coexistence-sync-conflits.md | 10h |
| #036 Formulaire de proposition depuis le panneau d'événement | 003-formulaire-proposition.md | 14h |
| #037 File de relecture, décisions publiques et appels | 004-file-de-relecture.md | 12h |
| #038 Transparence publique et RGPD des contributions | 005-transparence-publique-rgpd.md | 12h |
| #039 E2E, documentation d'exploitation et ADR surcouche | 006-e2e-documentation-adr.md | 8h |

## Dépendances

- Prérequis : F07 livrée (#030 à #033) : `@current_scope`, live_session `:require_authenticated_user`, pipeline `:authenticated`, `Amanogawa.Mailer`, `AmanogawaWeb.RateLimit`.
- Chaîne interne : #034 -> #035 et #034 -> #036 (parallélisables entre elles), puis #037 (consomme le rôle relecteur de #035 et les propositions de #036), puis #038, puis #039.
- Sortie : dernière feature du projet ; critère de sortie de la phase 2 (proposition d'édition, historique public, modération documentée) atteint à la clôture de #039.

## Risques

| Risque | Impact | Probabilité | Mitigation |
|--------|--------|-------------|------------|
| Écrasement silencieux entre sync et overrides (bug de préservation) | Perte de confiance, principe fondateur violé | Moyenne | Marqueur `overridden_fields` testé par intégration sync+overrides (#035), snapshots Wikidata dans les overrides, journal des divergences |
| Vandalisme ou spam de propositions | Charge de relecture, pollution du flux public | Moyenne | Relecture obligatoire avant visibilité carte, quotas IP et utilisateur, justification obligatoire bornée |
| Charge de modération sur un projet solo | File qui s'allonge, contributeurs découragés | Moyenne | File FIFO simple, quotas serrés au départ, promotion manuelle de relecteurs de confiance |
| Tension RGPD entre effacement et historique public | Risque juridique | Faible | Anonymisation (pas de suppression des contributions), arbitrage documenté (politique de confidentialité, ADR 0009), aucune donnée personnelle dans les justifications (règle publiée et modérée) |
| Divergence prolongée avec Wikidata sur des champs corrigés | Dérive du corpus local | Moyenne | Page d'examen des conflits (#035), résolution explicite (garder l'override ou adopter Wikidata), étude de la remontée vers Wikidata (V2) |
