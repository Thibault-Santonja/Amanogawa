# Issue #018 -- LiveView Explore : état central et URL partageable

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #015 (MapHook affichage des événements)

---

## Contexte

Jusqu'ici, la page carte est portée par la LiveView minimale de #005 : le hook affiche les événements mais l'état applicatif (fenêtre temporelle, sélection, filtres) n'a pas de propriétaire clair ni de persistance dans l'URL. Cette issue installe `AmanogawaWeb.ExploreLive`, la LiveView centrale de l'application, conformément à l'ADR 0005 : LiveView possède l'état et échange des intentions légères avec les hooks ; les volumes de données restent sur les endpoints JSON.

Responsabilités d'ExploreLive :

- **État central** : fenêtre temporelle (`from`, `to` en années astronomiques), sélection (`selected_qid`), filtres (`kinds`, liste optionnelle de types d'événements), position de carte (`z`, `lat`, `lng`) nécessaire aux liens partageables (« exactement la même vue », user story F03).
- **Synchronisation URL** : chaque changement d'état pertinent est reflété dans les query params via `push_patch` ; à l'inverse, `handle_params/3` est l'unique point d'entrée qui applique l'URL à l'état (chargements initiaux, navigation avant/arrière, liens partagés). Aucune requête base dans `mount/3` : `mount` n'assigne que des défauts, les chargements se font dans `handle_params/3` (loi d'airain LiveView).
- **Orchestration hook <-> LiveView** : la LiveView pousse `set_time_window` et `set_view` au hook ; le hook remonte `select_event` (posé en #016 si déjà livrée, sinon posé ici) et `map_moved` (débouncé côté client) ; la LiveView valide chaque payload client avant de l'appliquer.

Cette issue peut être livrée avant ou après #016 (les deux ne dépendent que de #015) : si #016 n'est pas encore livrée, ExploreLive reprend la page de #005 et pose les gestionnaires `select_event`/`deselect_event` en s'appuyant sur une fiche minimale ; si #016 est livrée, sa LiveView hôte et son panneau sont migrés tels quels dans ExploreLive.

## User Story

> En tant que visiteur, je veux que la vue courante (période, position de carte, événement sélectionné) soit encodée dans l'URL, afin de partager un lien qui restitue exactement ce que je regarde et de naviguer avec les boutons avant/arrière du navigateur.

---

## Tâches

- [ ] Créer `AmanogawaWeb.ExploreLive` et la brancher dans `router.ex` (route de la page carte, en remplacement de la LiveView minimale de #005 ; supprimer l'ancienne pour ne laisser qu'une LiveView par page).
- [ ] `mount/3` : assigns par défaut uniquement (fenêtre complète, aucune sélection, filtres vides, vue monde) ; aucune requête base, aucun appel externe.
- [ ] Créer `AmanogawaWeb.Params.ExploreParams` : parsing et validation des query params (`from`, `to`, `sel`, `kinds`, `z`, `lat`, `lng`) avec les mêmes bornes que l'API (#014) : années dans [-13_800_000_000, année courante] et `from <= to`, `sel` au format `^Q\d+$`, `z` dans [0, 22], `lat`/`lng` dans les bornes monde, `kinds` restreint à l'énumération des types connus. Tout paramètre invalide est remplacé par sa valeur par défaut (URL partagée dégradée plutôt qu'erreur 500).
- [ ] `handle_params/3` : applique les params validés aux assigns ; si `sel` présent et différent de la sélection courante, charge l'événement via `Amanogawa.Atlas` (ici, pas dans mount) et ouvre la fiche ; pousse au hook `set_time_window` (`from`, `to`) et `set_view` (`z`, `lat`, `lng`) quand ces valeurs proviennent de l'URL.
- [ ] `handle_event("select_event", ...)` et `handle_event("deselect_event", ...)` : validation du payload puis `push_patch` vers l'URL mise à jour (ajout/retrait de `sel`) ; le chargement effectif découle de `handle_params` (source de vérité unique) ; conserver les push d'événements `event_selected`/`event_deselected` vers le hook (contrat #016/#017).
- [ ] `handle_event("map_moved", %{"z" => _, "lat" => _, "lng" => _})` : payload validé puis `push_patch` avec `replace: true` (pas une entrée d'historique par déplacement de carte) ; côté hook, pousser `map_moved` débouncé (réutiliser `debounce.js` de #015) sur `moveend`, en veillant à ne pas boucler (un `set_view` reçu du serveur ne doit pas redéclencher un `map_moved`).
- [ ] `handle_event("set_time_window", ...)` : intention de changement de fenêtre (posée pour la frise F04 et d'éventuels contrôles UI), validée puis répercutée par `push_patch`.
- [ ] Filtres `kinds` : état et encodage URL posés dans cette issue ; l'UI de filtrage peut rester minimale (liste de cases dans un panneau), l'essentiel est le contrat état + URL.
- [ ] Étendre `MapHook` : gestionnaire `set_view` (`jumpTo`, ou `easeTo` si `prefers-reduced-motion` absent) et émission `map_moved` débouncée avec garde anti-boucle.
- [ ] Vérifier l'ensemble du cycle : URL collée dans un nouvel onglet restitue fenêtre, position, sélection ; boutons avant/arrière du navigateur rejouent les états via `handle_params`.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `ExploreParams` parse une URL complète valide (`from`, `to`, `sel`, `z`, `lat`, `lng`, `kinds`) vers l'état attendu.
- [ ] **Edge case** : params partiels complétés par les défauts ; `kinds` vide ou absent ; années négatives extrêmes valides.
- [ ] **Error case** : `from > to`, `sel` malformé, `z`/`lat`/`lng` hors bornes, valeurs non numériques : chaque param invalide retombe sur son défaut sans invalider les autres.
- [ ] **Limit case** : bornes exactes acceptées (`from=-13800000000`, `z=0`, `z=22`, `lat=90`, `lng=-180`).

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : round-trip : pour tout état valide généré, encoder vers query params puis re-parser redonne le même état.
- [ ] **Property** (StreamData) : pour toute map de query params arbitraire (y compris hostile), le parsing ne lève jamais et retourne un état dans les bornes.

### Doctests (si applicable)

- [ ] **Doctest** : encodage d'un état nominal en query params dans `ExploreParams`.

### Tests d'intégration

- [ ] **Intégration** (LiveViewTest) :
  - mount sans params : rendu avec défauts, aucune fiche ouverte ;
  - navigation vers une URL avec `from`/`to` : `assert_push_event` `set_time_window` avec les bornes ;
  - URL avec `sel` valide : fiche rendue (contenu de l'événement), `assert_push_event` `event_selected` ;
  - `select_event` poussé par le client : `push_patch` observé (`assert_patch`) avec `sel` dans l'URL, fiche ouverte ; `deselect_event` : `sel` retiré, fiche fermée ;
  - `map_moved` valide : URL patchée avec `z`/`lat`/`lng` ; payload hostile (`z=999`, `lat=abc`) : état inchangé, pas de crash ;
  - navigation arrière simulée (re-`handle_params` sur l'URL précédente) : état restauré.
- [ ] **Intégration** : vérifier par test que `mount/3` ne déclenche aucune requête base (par exemple en assertant qu'aucune requête n'est loguée pendant mount via télémétrie Ecto, ou a minima revue structurelle : tout accès Atlas vit dans `handle_params`/`handle_event`).

### Tests end-to-end (si applicable)

- [ ] **E2E** (parcours critique complet) : charger `/`, attendre les événements sur la carte ; sélectionner un événement ; vérifier l'ouverture de la fiche et la présence de `sel` dans l'URL ; recharger l'URL courante dans une nouvelle session : même vue restituée (fenêtre, position, fiche ouverte) ; vérifier le lien Wikipedia de la fiche.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa_web/live/explore_live.ex` (+ HEEx colocalisé ou `explore_live.html.heex`)
  - `lib/amanogawa_web/params/explore_params.ex`
  - `lib/amanogawa_web/router.ex` (route Explore, retrait de la LiveView minimale de #005)
  - `assets/js/hooks/map.js` (gestionnaire `set_view`, émission `map_moved` débouncée)
  - Tests miroirs sous `test/amanogawa_web/live/` et `test/amanogawa_web/params/`
- **Documentation de référence** : ADR 0005 (répartition état/volumes), `.claude/rules/liveview.md` (pas de requête en mount, événements nommés en verbes explicites, validation des payloads), `.claude/rules/security.md` (bornage de tout input utilisateur), issues #014 (bornes partagées), #016 et #017 (contrats d'événements sélection).
- **Compétences requises** : LiveView avancé (`handle_params`, `push_patch`, `assert_patch`, `assert_push_event`), conception d'URL comme source de vérité, hooks (`pushEvent`/`handleEvent`), tests LiveViewTest et E2E.
- **Points d'attention** :
  - `handle_params` est l'unique endroit qui applique l'URL à l'état : les `handle_event` ne modifient pas l'état directement, ils patchent l'URL (évite deux sources de vérité et fait fonctionner l'historique navigateur gratuitement).
  - `replace: true` pour `map_moved` : sans lui, chaque glissement de carte pollue l'historique.
  - Garde anti-boucle `set_view`/`map_moved` obligatoire : marquer les déplacements programmatiques dans le hook et ignorer le `moveend` qui en découle.
  - Les bornes de validation sont les mêmes que #014 : factoriser les constantes (module partagé côté Elixir) plutôt que dupliquer les littéraux.
  - Ne pas stocker de liste d'événements dans les assigns : les volumes restent dans le hook et les endpoints (streams si une liste UI devient nécessaire plus tard).
  - Si #016 est livrée avant : migrer sa LiveView hôte et `EventPanel` dans ExploreLive sans changer leurs contrats ; sinon, poser une fiche minimale et laisser #016 la compléter.
  - Pas de tirets cadratins ni de mention d'outillage dans le code et les commits.
