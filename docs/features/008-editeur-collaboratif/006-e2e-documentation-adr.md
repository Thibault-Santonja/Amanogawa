# Issue #039 -- E2E, documentation d'exploitation et ADR surcouche

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #038

---

## Contexte

Dernière issue de F08 et du projet : prouver les parcours de bout en bout dans un vrai navigateur, donner à l'opérateur ce qu'il faut pour faire vivre la modération, et acter la décision structurante de la feature dans un ADR. C'est le critère de sortie de la phase 2 (roadmap : "proposition d'édition, historique public des révisions, modération documentée").

**E2E Wallaby** (suite existante : `test/e2e/`, leçons F03/F07 dans `.claude/memory/tech-stack.md` : Chrome for Testing + chromedriver sans quarantine en local, headless=new en CI) :

- **Parcours contributeur** : connexion par magic link, choix du pseudonyme, sélection d'un événement sur la carte, proposition d'une correction de date avec précision et justification, vérification que la valeur affichée est inchangée, retrouvaille de la proposition "en attente" sur `/contributions`.
- **Parcours relecteur** : compte promu relecteur (setup direct en base, comme le fera l'opérateur), ouverture de `/relecture`, examen du diff, acceptation avec motif ; la valeur corrigée apparaît dans le panneau de l'événement avec la mention "valeur corrigée", la décision et son motif sont visibles sur la page publique de la contribution.
- **Parcours rejet et appel** : rejet motivé, l'auteur voit le motif sur la page publique, répond une fois, la seconde réponse est impossible, le relecteur tranche.

**Documentation d'exploitation** (`docs/ops/`) :

- Nouveau `docs/ops/moderation.md` : promouvoir un relecteur (UPDATE SQL documenté sur `accounts.users.role`, choix V1 assumé de la promotion manuelle), rythme conseillé de relecture, examen des conflits de sync sur `/relecture/conflits` (quand les examiner : après chaque sync mensuelle, lecture du résumé de `SyncRun`), conduite à tenir sur un compte abusif (quotas, et rappel que la suppression de compte anonymise sans effacer l'historique).
- Mise à jour de `docs/ops/sync.md` : la sync préserve les champs surchargés, les compteurs de divergences dans le résumé de run, le renvoi vers l'examen des conflits.

**ADR 0009 "Surcouche de contributions" (nouveau, format Nygard, `docs/adr/0009-surcouche-de-contributions.md`)** : c'est une décision structurante qui doit survivre à la feature. Contexte (données en couches non négociables, sync mensuelle, requête viewport critique) ; Décision ("Nous allons...") : surcouche `contributions.overrides` avec résolution à l'écriture dans `atlas.events` via l'API publique d'Atlas (marqueur `overridden_fields`, snapshots Wikidata dans les overrides), préservation par ligne et par colonne dans l'upsert de sync, journalisation des divergences, identifiants locaux `L<uuid>` pour les événements communautaires, anonymisation (pas suppression) des contributions à la suppression de compte ; Conséquences positives (chemin de lecture inchangé, traçabilité et réversibilité complètes, historique public cohérent), négatives (double vérité à maintenir entre colonnes résolues et snapshots, complexité de l'upsert conditionnel), compromis (liens en ajout seulement en V1, remontée vers Wikidata reportée) ; Alternatives considérées : vue matérialisée (un paragraphe), jointure à la lecture (un paragraphe), fork complet du corpus sans resync (un paragraphe). Indexer dans `docs/adr/README.md`.

Également dans cette issue : mise à jour de `docs/roadmap.md` (statut F08, critère de sortie phase 2) et de la vue d'ensemble F08 (statut "livrée" à la clôture).

## User Story

> En tant que mainteneur du projet, je veux des parcours contributeur et relecteur prouvés en navigateur, une exploitation documentée et la décision de surcouche actée en ADR, afin de clore la phase 2 avec un collaboratif vérifié et transmissible.

---

## Tâches

- [ ] `test/e2e/contribution_journey_test.exs` : parcours contributeur complet (connexion magic link réutilisant les helpers E2E de F07, pseudonyme, proposition de date via le formulaire typé, justification, flux public) ; sélecteurs stables (ids/dataset) plutôt que textes localisés.
- [ ] `test/e2e/review_journey_test.exs` : parcours relecteur (promotion en base dans le setup, file, diff, acceptation motivée, vérification carte + page publique) et parcours rejet-appel-décision finale (une seule réponse possible).
- [ ] Vérifier dans les parcours E2E les invariants éthiques observables : aucune valeur non relue visible sur la carte, motifs publics accessibles sans compte, aucun compteur de gamification à l'écran.
- [ ] `docs/ops/moderation.md` (nouveau) : promotion relecteur, revue régulière, examen des conflits, comptes abusifs, renvoi vers `/moderation` pour les règles publiques.
- [ ] `docs/ops/sync.md` : section divergences (préservation, compteurs, examen post-sync).
- [ ] `docs/adr/0009-surcouche-de-contributions.md` (format Nygard, contenu cadré ci-dessus) + index `docs/adr/README.md`.
- [ ] `docs/roadmap.md` et `docs/features/008-editeur-collaboratif/000-editeur-collaboratif.md` : statuts et critère de sortie de la phase 2 mis à jour.
- [ ] `.claude/memory/` : consigner les décisions et leçons de F08 (mécanisme de résolution, pièges rencontrés), hors commit comme toujours.

---

## Tests à écrire

### Tests unitaires

- [ ] Non applicable : issue de vérification bout en bout et de documentation ; les unités sont couvertes par #034 à #038.

### Property-based tests (si applicable)

- [ ] Non applicable.

### Doctests (si applicable)

- [ ] Non applicable.

### Tests d'intégration

- [ ] **Intégration (revue transverse)** : passer la suite complète et la couverture par module (> 90%, excoveralls) sur l'ensemble du contexte Contributions et des LiveViews de F08 ; combler les trous découverts ici plutôt que de les reporter.

### Tests end-to-end (si applicable)

- [ ] **E2E (Wallaby, contributeur)** : le parcours contributeur ci-dessus, avec assertion explicite que la valeur affichée reste la valeur d'origine tant que rien n'est accepté.
- [ ] **E2E (Wallaby, relecteur)** : le parcours acceptation ; après acceptation, recharger la carte et vérifier la valeur corrigée et sa mention de provenance dans le panneau.
- [ ] **E2E (Wallaby, rejet et appel)** : motif public visible déconnecté ; appel possible une fois exactement ; décision finale visible dans l'historique public.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `test/e2e/contribution_journey_test.exs`, `test/e2e/review_journey_test.exs`, helpers partagés dans `test/support/` si la connexion E2E de F07 doit être factorisée
  - `docs/ops/moderation.md` (nouveau), `docs/ops/sync.md`
  - `docs/adr/0009-surcouche-de-contributions.md` (nouveau), `docs/adr/README.md`
  - `docs/roadmap.md`, `docs/features/008-editeur-collaboratif/000-editeur-collaboratif.md`
- **Documentation de référence** : `.claude/rules/issues.md` (format ADR Nygard, numérotation continue immuable), `docs/adr/0000-template.md`, leçons Wallaby de `.claude/memory/tech-stack.md` (chromedriver local, CI headless, swiftshader), vue d'ensemble F08 (tout l'arbitrage à acter dans l'ADR), suites E2E existantes (`test/e2e/`).
- **Compétences requises** : Wallaby (parcours multi-pages, deux sessions utilisateur), rédaction d'ADR, documentation d'exploitation.
- **Points d'attention** :
  - L'ADR décrit la décision et ses raisons, pas l'implémentation ligne à ligne : il doit rester vrai même si le code bouge ; une fois accepté il ne s'édite plus (le remplacer par un successeur si la décision change).
  - Les E2E ne touchent JAMAIS Wikidata/Wikipedia (règle absolue) : corpus de test inséré par fixtures, magic link récupéré via l'adaptateur local.
  - Deux rôles dans un même test Wallaby = deux sessions navigateur distinctes ; ne pas partager les cookies entre contributeur et relecteur.
  - `mix precommit` et Credo/Sobelow doivent passer sur l'ensemble de F08 avant de clore ; c'est la dernière issue, ne rien laisser en "à faire plus tard".
  - La documentation ops s'adresse à un opérateur self-host qui n'a pas lu le code : chaque procédure doit être exécutable telle quelle (commandes complètes, y compris le psql de promotion).
