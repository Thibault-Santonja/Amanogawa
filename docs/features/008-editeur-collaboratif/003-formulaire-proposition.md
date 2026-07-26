# Issue #036 -- Formulaire de proposition depuis le panneau d'événement

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 14h
**Prérequis :** #034

---

## Contexte

Le contexte Contributions (#034) sait enregistrer une proposition ; cette issue donne aux utilisateurs le moyen d'en faire une, depuis l'endroit où l'erreur se voit : le panneau d'événement (`AmanogawaWeb.Components.EventPanel`, ouvert par la sélection d'un marqueur dans `AmanogawaWeb.ExploreLive`). Périmètre V1 (décision de cadrage) : corrections d'événements existants (dates avec précision, position, libellés, ajout de liens) et proposition de nouveaux événements. Rien n'est jamais appliqué directement : tout part en file de relecture (#037) avec le statut `:pending`, et la valeur affichée ne bouge pas.

Le formulaire est TYPÉ selon le champ corrigé :

- **Date (`begin_date`, `end_date`)** : année (entier signé, convention astronomique), mois et jour optionnels, précision (échelle Wikidata 0-11, libellés lisibles), calendrier ; validation par `Amanogawa.HistoricalDate.changeset/2` rejouée serveur (jamais de date sans précision, Iron Law). Pour `end_date`, une case explicite "retirer la date de fin" produit la valeur proposée nulle (#034).
- **Position** : par clic sur la carte. Le formulaire passe le MapHook en mode "choisir une position" (`push_event` serveur -> hook) ; le clic suivant renvoie `{lng, lat}` (`pushEvent` hook -> serveur, payload validé et borné au monde côté serveur, jamais de confiance au client). Aperçu des coordonnées choisies avant envoi, marqueur temporaire nettoyé à l'annulation et dans `destroyed()`.
- **Libellés (`label_fr`, `label_en`)** : champ texte borné, non vide.
- **Lien** : QID cible saisi (format validé par `AmanogawaWeb.Params.EventId`), existence vérifiée via `Amanogawa.Atlas.get_event_by_qid/1` avec affichage du libellé cible pour confirmation, type parmi les cinq (`part_of`, `follows`, `cause`, `effect`, `significant`) avec intitulés expliqués. Ajout uniquement (V1, vue d'ensemble).
- **Nouvel événement** : libellé (fr ou en requis), date de début avec précision, position par clic carte, description optionnelle ; accessible par un bouton sobre de la page d'exploration, réutilisant les mêmes sous-formulaires.

Dans TOUS les cas : justification obligatoire (URL ou référence textuelle, 5 à 1000 caractères, comptée et annoncée dans l'UI), et quotas anti-abus AVANT toute écriture : `Amanogawa.Contributions.ProposalThrottle`, calqué sur `Amanogawa.Accounts.MagicLinkThrottle` (couche sur `AmanogawaWeb.RateLimit`, l'unique limiteur Hammer ETS du projet, clés préfixées `contribution:user:` et `contribution:ip:`, compteurs indépendants, limites configurables par environnement, défaut proposé : 10 par heure).

Accès : l'entrée "Proposer une correction" est visible de tous dans le panneau ; pour un anonyme elle mène à `/connexion` (avec retour vers l'événement après connexion, mécanique `user_return_to` de F07) : la contribution est un droit affiché, pas un privilège caché, mais l'écriture exige un compte (`@current_scope.user`). Première proposition d'un compte sans `display_name` : le formulaire demande d'abord le pseudonyme public (#034, `Amanogawa.Accounts.set_display_name/2`), en expliquant qu'il attribuera publiquement les révisions.

Impact système : `ExploreLive` gagne un composant de formulaire (LiveComponent, état isolé justifié), le MapHook gagne un mode de sélection de position, aucune route nouvelle en dehors du paramètre de patch ouvrant le formulaire.

## User Story

> En tant qu'utilisateur connecté qui repère une erreur (date, position, libellé, lien manquant) ou un événement absent, je veux proposer une correction sourcée depuis le panneau de l'événement, afin qu'un relecteur puisse l'examiner sans que la carte affiche quoi que ce soit de non relu.

---

## Tâches

- [ ] `Amanogawa.Contributions.ProposalThrottle` : `allow?/2` (user_id, ip), clés préfixées sur `AmanogawaWeb.RateLimit`, config `config :amanogawa, Amanogawa.Contributions.ProposalThrottle` (limite et fenêtre), branché dans le chemin d'écriture AVANT `Amanogawa.Contributions.propose/2` (défense côté domaine, pas seulement côté UI).
- [ ] LiveComponent `AmanogawaWeb.Live.ProposalFormComponent` : ouvert par `push_patch` (paramètre d'URL, l'état survit au refresh), choix du champ à corriger, sous-formulaires typés ci-dessus, justification obligatoire avec compteur, messages d'erreur localisés, envoi -> `Amanogawa.Contributions.propose/2` -> flash sobre "Proposition envoyée, elle sera relue" et fermeture.
- [ ] `AmanogawaWeb.Components.EventPanel` : entrée "Proposer une correction" (icône discrète, pas de call-to-action agressif : anti-dark-patterns) ; anonyme -> lien vers `/connexion` avec retour.
- [ ] MapHook (`assets/js/hooks/`) : mode "choisir une position" (curseur dédié, un clic pousse `position_picked` avec `{lng, lat}` débruité, marqueur temporaire, annulation par Escape) ; nettoyage complet en `destroyed()` et à la fermeture du formulaire.
- [ ] Parcours nouvel événement : bouton "Proposer un événement" sur la page d'exploration (visible connecté, sinon `/connexion`), même composant en mode création, mêmes validations.
- [ ] Parcours `display_name` : si `@current_scope.user` n'a pas de pseudonyme, le formulaire l'exige d'abord (validation 3-40, unicité, message d'explication de l'attribution publique) ; champ également éditable sur `/compte` (extension légère d'`AccountLive`).
- [ ] Validations serveur systématiques dans `handle_event` (règle LiveView : ne jamais faire confiance aux payloads clients) : formats, bornes monde, longueurs ; les erreurs de quota affichent un message neutre avec la fenêtre de réessai, sans compteur culpabilisant.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `ProposalThrottle.allow?/2` sous la limite retourne true et compte séparément user et IP (l'épuisement de l'un bloque même si l'autre est libre).
- [ ] **Edge case** : la limite utilisateur atteinte par un user derrière deux IP bloque quand même (clé user) ; la limite IP atteinte par deux comptes sur la même IP bloque quand même (clé IP).
- [ ] **Error case** : payload de position hors bornes (`lat > 90`), année hors bornes projet, QID cible mal formé : rejetés serveur avec erreurs de changeset, rien n'est écrit.
- [ ] **Limit case** : justification de 5 et de 1000 caractères acceptée, 4 et 1001 rejetée (bornes exactes).

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute date générée valide au sens de `HistoricalDate`, la soumission du sous-formulaire date produit un payload d'override qui revalide sans erreur (le formulaire ne sait pas fabriquer de date invalide) ; pour toute date invalide générée (jour sans mois, précision incohérente), la soumission est rejetée.

### Doctests (si applicable)

- [ ] Non applicable : composants et throttle, rien de pur à documenter par l'exemple.

### Tests d'intégration

- [ ] **Intégration (LiveViewTest, ExploreLive)** : connecté avec pseudonyme, sélection d'un événement, ouverture du formulaire, proposition d'une correction de `begin_date` avec justification : un override `:pending` attribué existe en base, la valeur affichée dans le panneau est inchangée, flash sobre affiché.
- [ ] **Intégration (LiveViewTest)** : proposition de position : l'événement simulé `position_picked` remplit l'aperçu, la soumission stocke un Point 4326 correct ; proposition de lien vers un QID existant : libellé cible affiché puis override `:link` créé ; QID inconnu localement : erreur explicite, rien n'est écrit.
- [ ] **Intégration (LiveViewTest)** : anonyme : l'entrée du panneau mène à `/connexion` et le retour post-connexion revient sur l'événement ; connecté sans `display_name` : le formulaire exige le pseudonyme avant toute proposition.
- [ ] **Intégration (LiveViewTest, quotas)** : au-delà de la limite configurée (config test basse), la soumission est refusée avec message neutre et aucun override supplémentaire n'est créé.
- [ ] **Intégration (LiveViewTest, nouvel événement)** : le parcours création aboutit à un override `:new_event` `:pending` complet ; aucun événement n'apparaît dans `atlas.events` avant acceptation.

### Tests end-to-end (si applicable)

- [ ] Couvert par #039 (parcours contributeur Wallaby complet, incluant le vrai clic carte).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/contributions/proposal_throttle.ex`, `lib/amanogawa/contributions.ex` (branchement du throttle)
  - `lib/amanogawa_web/live/proposal_form_component.ex`, `lib/amanogawa_web/live/explore_live.ex` (paramètre de patch, assigns, événements), `lib/amanogawa_web/components/event_panel.ex`
  - `lib/amanogawa_web/live/account_live.ex` (édition du pseudonyme)
  - `assets/js/hooks/map_hook.js` (mode position ; respecter les conventions d'événements existantes serveur -> hook / hook -> serveur, `.claude/memory/tech-stack.md`)
  - `test/amanogawa/contributions/proposal_throttle_test.exs`, `test/amanogawa_web/live/explore_live_test.exs` (extension), `test/amanogawa_web/live/proposal_form_component_test.exs`, `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : vue d'ensemble F08 (quotas, anti-dark-patterns, arbitrage `display_name`), #034 (façade `propose/2`, payloads), `.claude/rules/liveview.md` (pas de requête dans mount, validation des payloads, hooks vanilla), `.claude/rules/security.md` (bornage serveur), F07 #032 (`user_return_to`), précédent `MagicLinkThrottle`.
- **Compétences requises** : LiveView (LiveComponent, push_patch, formulaires imbriqués), hooks MapLibre existants, Hammer, Gettext fr/en.
- **Points d'attention** :
  - Le quota se vérifie dans le DOMAINE (façade) et pas seulement dans l'UI : une future API de proposition ne doit pas pouvoir le contourner.
  - `current_value` de l'override se snapshote à la proposition (pour le diff de #037) : c'est `propose/2` qui le fait, le composant n'envoie que la valeur proposée.
  - Le mode position doit relâcher proprement la carte (leçons E2E F03 : nettoyage des listeners, ResizeObserver, marqueurs) ; Escape annule sans fermer le panneau.
  - Précision des dates : proposer les libellés humains de l'échelle Wikidata (siècle, décennie, année, mois, jour) plutôt que les entiers bruts ; ne jamais permettre jour sans mois (l'invariant `HistoricalDate` le rejettera de toute façon).
  - Aucune gamification : pas de compteur de contributions dans le formulaire, pas de "plus que X pour...", flash de confirmation neutre.
  - L'entrée du panneau reste discrète pour ne pas dégrader la lecture (le panneau est d'abord une fiche de consultation).
