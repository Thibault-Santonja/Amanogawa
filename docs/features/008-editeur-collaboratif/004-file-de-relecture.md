# Issue #037 -- File de relecture, décisions publiques et appels

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #035, #036

---

## Contexte

Les propositions existent (#036) et le rôle relecteur est en place avec son gating web (#035 : colonne `role`, hook `on_mount(:require_reviewer)`, live_session `:require_reviewer`). Cette issue livre le coeur du workflow de modération V1 (décision de cadrage) : toute contribution est une proposition ; un relecteur accepte ou rejette avec un motif PUBLIC ; l'auteur peut répondre UNE fois (appel) ; le relecteur re-décide alors définitivement. Chaque étape est journalisée dans `contributions.revisions` (#034), donc publique par construction.

La file de relecture est une LiveView `/relecture` strictement chronologique (FIFO, plus ancienne proposition d'abord : aucune priorisation algorithmique, principe anti-dark-patterns ; le seul filtre est factuel : par kind ou par événement). Pour chaque proposition, un diff lisible avant/après :

- dates : les deux valeurs formatées selon leur précision par `Amanogawa.HistoricalDate.Formatter` (jamais d'affichage faussement précis, ADR 0006) ;
- position : coordonnées avant/après et distance approximative, avec lien de visualisation sur la carte (`/?...` centré) ;
- libellés : avant/après en toutes lettres ;
- lien : événement source, cible (libellé + QID) et type expliqué ;
- nouvel événement : fiche complète proposée.

Le "avant" vient du snapshot `current_value` pris à la proposition (#036) ; si la valeur en base a changé depuis (sync passée entre temps), l'écart est signalé au relecteur (badge "la valeur de référence a changé depuis la proposition") : il décide en connaissance de cause.

Décisions : `accept_override/3` (#034) applique la surcouche via l'API publique Atlas et journalise ; `reject_override/3` journalise avec motif. L'appel : sur SA proposition rejetée, l'auteur peut soumettre une unique réponse (`appeal_override/3` : vérifie l'auteur, vérifie qu'aucun appel n'existe déjà, journalise `:appealed` avec le texte public borné) ; la proposition revient dans la file marquée "en appel" et le relecteur (idéalement un autre, en V1 le même est accepté : projet solo) tranche par `review_appeal/3` (`:accepted` ou rejet définitif, révision `:appeal_reviewed` avec motif). Après l'issue de l'appel, plus aucune action possible.

Notifications par email, sobres par principe (ADR 0008, anti-dark-patterns) : un email texte brut à l'auteur À LA DÉCISION uniquement (acceptation, rejet avec motif, issue d'appel), envoyé via un behaviour `Amanogawa.Contributions.DecisionNotifier` + adaptateur Swoosh sur `Amanogawa.Mailer` (même pattern que `MagicLinkNotifier`, mock Mox en test). Aucun email d'engagement : pas de rappel, pas de résumé périodique, pas de "votre proposition attend", aucune image ni lien de tracking. L'email contient le motif public et le lien vers la page publique de la contribution (#038 ; l'URL est construite dès maintenant, la page arrive dans l'issue suivante et l'E2E de #039 valide la chaîne complète).

Impact système : routes `/relecture` (et actions LiveView associées), fonctions de façade de décision et d'appel, notifier ; aucune modification du chemin de lecture public.

## User Story

> En tant que relecteur, je veux examiner les propositions dans l'ordre de leur arrivée avec un diff lisible et décider avec un motif public, et en tant qu'auteur, je veux pouvoir répondre une fois à un rejet, afin que la modération soit transparente, journalisée et appelable.

---

## Tâches

- [ ] Façade Contributions : `appeal_override/3` (auteur seul, une seule fois, texte public borné 5 à 1000, uniquement sur `:rejected`, journalise `:appealed`) et `review_appeal/3` (relecteur, décision finale, motif obligatoire, journalise `:appeal_reviewed` ; l'acceptation en appel applique la surcouche comme `accept_override/3`) ; `list_review_queue/1` (pending et en appel, ordre chronologique strict, filtres factuels kind/événement, pagination keyset).
- [ ] `Amanogawa.Contributions.DecisionNotifier` (behaviour) + `Amanogawa.Contributions.DecisionNotifier.Email` (Swoosh via `Amanogawa.Mailer`, texte brut, fr/en selon la locale du destinataire si connue sinon fr, motif inclus, lien public inclus) ; configuration `Application.get_env(:amanogawa, :decision_notifier)`, mock Mox en test ; l'échec d'envoi est loggué avec tag borné et ne fait JAMAIS échouer la décision (précédent `Amanogawa.Accounts.send_magic_link/3`).
- [ ] Appel du notifier depuis `accept_override/3`, `reject_override/3`, `review_appeal/3` APRÈS commit de la transaction (jamais d'email pour une décision annulée par rollback) ; l'adresse email est résolue à l'envoi via la façade Accounts (jamais stockée dans contributions).
- [ ] LiveView `AmanogawaWeb.ReviewQueueLive` sur `/relecture` (live_session `:require_reviewer` de #035) : file chronologique en streams (pas de requête dans `mount/3`), panneau de détail par proposition avec le diff typé ci-dessus, badge "valeur de référence modifiée depuis la proposition", justification et source de l'auteur en évidence, actions accepter/rejeter avec zone de motif obligatoire, section appel (texte de l'auteur) avec décision finale.
- [ ] Signalement de l'écart de référence : comparaison entre `current_value` snapshoté et la valeur actuellement en base (lecture via la façade Atlas), calculée au rendu du détail.
- [ ] Vue auteur minimale pour l'appel : sur la page de détail public de la contribution (route posée ici, `/contributions/:id`, live_session `:current_user` ; la mise en page complète et le flux public arrivent en #038), l'auteur connecté d'une proposition `:rejected` sans appel voit le formulaire de réponse unique.
- [ ] Textes fr/en (Gettext) pour la file, les motifs, les emails.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `appeal_override/3` par l'auteur sur un rejet journalise `:appealed` et repasse la proposition dans la file ; `review_appeal/3` acceptant applique la surcouche (valeur visible via Atlas) et journalise.
- [ ] **Edge case** : second appel sur la même proposition refusé (une seule réponse, décision de cadrage) ; appel sur une proposition `:pending` ou `:accepted` refusé.
- [ ] **Error case** : `appeal_override/3` par un autre utilisateur que l'auteur : erreur taguée, rien n'est journalisé (anti-IDOR) ; `review_appeal/3` par un non-relecteur refusé ; motif vide refusé sur toutes les décisions.
- [ ] **Limit case** : `list_review_queue/1` ordonne strictement par date de proposition, appels compris (un appel ne "remonte" pas la file : il garde la date d'origine) ; pagination stable sous insertions concurrentes (keyset).

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute séquence d'actions générée sur une proposition (propose, reject, appeal, review_appeal...), seules les séquences conformes à la machine à états (pending -> accepted | rejected ; rejected -> appealed -> décision finale ; terminal ensuite) réussissent ; toute transition hors machine échoue sans modifier l'état.

### Doctests (si applicable)

- [ ] Non applicable : fonctions de façade avec base et notifications.

### Tests d'intégration

- [ ] **Intégration (DataCase + Mox, notifications)** : accepter, rejeter et trancher un appel déclenchent chacun exactement UN appel au notifier avec le motif dedans ; un échec du notifier (mock en erreur) laisse la décision commitée et logguée ; aucune notification n'est envoyée pour une proposition simplement soumise (pas d'email d'engagement).
- [ ] **Intégration (LiveViewTest, ReviewQueueLive)** : relecteur : la file affiche les propositions dans l'ordre, le diff d'une date est formaté selon les deux précisions, accepter avec motif fait disparaître la proposition de la file et la valeur corrigée apparaît via la façade Atlas ; rejeter exige le motif.
- [ ] **Intégration (LiveViewTest, appel)** : l'auteur voit le formulaire d'appel sur sa proposition rejetée, le soumet, ne peut plus le soumettre à nouveau ; un autre utilisateur connecté ne voit pas le formulaire ; le relecteur voit l'appel dans la file et tranche.
- [ ] **Intégration (LiveViewTest, badge de référence)** : modifier la valeur en base entre proposition et relecture (simulant une sync) affiche le badge d'écart.
- [ ] **Intégration (accès)** : `/relecture` redirige un connecté non relecteur avec flash neutre et un anonyme vers `/connexion` (réutilise les tests du hook de #035, étendus à cette route).

### Tests end-to-end (si applicable)

- [ ] Couvert par #039 (parcours relecteur Wallaby complet).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/contributions.ex` (appel, review d'appel, file), `lib/amanogawa/contributions/decision_notifier.ex`, `lib/amanogawa/contributions/decision_notifier/email.ex`
  - `lib/amanogawa_web/live/review_queue_live.ex`, `lib/amanogawa_web/live/contribution_live.ex` (détail minimal `/contributions/:id`, complété en #038), `lib/amanogawa_web/router.ex`
  - `config/config.exs` et `config/test.exs` (notifier configuré, mock en test)
  - `test/amanogawa/contributions_test.exs` (extension), `test/amanogawa_web/live/review_queue_live_test.exs`, `test/amanogawa_web/live/contribution_live_test.exs`, `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : vue d'ensemble F08 (workflow de modération V1, anti-dark-patterns), #034 (machine à états des statuts, révisions), #035 (gating relecteur), F07 #031 (pattern notifier + Mox, logging borné des échecs SMTP), ADR 0006 (formatage par précision).
- **Compétences requises** : LiveView (streams, formulaires conditionnels), Swoosh/Mox, machine à états en changesets, rédaction d'emails transactionnels sobres fr/en.
- **Points d'attention** :
  - Permission vérifiée dans le DOMAINE avant chaque mutation (rôle, auteur), jamais seulement par le routage : la façade est appelable d'ailleurs.
  - L'email de décision part APRÈS le commit ; si l'application redémarre entre commit et envoi, l'email est perdu : acceptable en V1 (la décision reste consultable publiquement), le noter dans le moduledoc plutôt que d'introduire un job Oban prématuré.
  - Ne JAMAIS mettre l'adresse email dans les révisions ni dans un motif ; les motifs sont publics par destination et affichés tels quels (échappés par HEEx).
  - L'auto-relecture est interdite (`accept_override/3` refuse l'auteur, #034) ; pour l'appel, le même relecteur peut trancher en V1 (projet solo), documenté sur `/moderation` (#038).
  - FIFO signifie FIFO : résister à la tentation d'un tri par "importance" de l'événement ; le seul confort autorisé est le filtre factuel.
  - Le lien public dans l'email pointe vers `/contributions/:id` : garder l'URL stable (elle est promise dans des emails déjà partis).
