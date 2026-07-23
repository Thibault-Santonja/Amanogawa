# Issue #021 -- Fenêtre temporelle : drag, resize, sync

**Feature :** F04 -- Frise chronologique
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #020, #018

---

## Contexte

La frise rendue en #020 est encore statique. Cette issue la rend interactive : une fenêtre temporelle matérialisée sur la frise, dont l'utilisateur peut déplacer chaque borne indépendamment (resize) ou faire glisser le corps entier (translation à largeur constante). C'est LE geste central du produit : la fenêtre pilote les événements affichés par la carte (F03) et, en #022, le gradient de couleur.

L'architecture de synchronisation suit l'ADR 0005 : la LiveView Explore (#018) est propriétaire de l'état (fenêtre courante, reflétée dans l'URL partageable) ; le hook possède le rendu et le geste. Le flux est bidirectionnel :

- client -> serveur : pendant le drag, le hook met à jour le rendu localement à 60 fps sans rien pousser ; après 150 ms sans mouvement (debounce, règle LiveView), il envoie `pushEvent("select_time_window", %{from, to})`. Le serveur valide (jamais de confiance dans les params client), met à jour ses assigns et patche l'URL.
- serveur -> client : au `handle_params` (navigation, URL collée, bouton retour), la LiveView pousse `push_event("time_window_changed", %{from, to})` et le hook repositionne la fenêtre. Une garde anti-écho est nécessaire pour ne pas boucler (voir Points d'attention).

Les contraintes du geste : bornes clampées au domaine de `TimeScale` (min/max), largeur minimale paramétrée (défaut : 1 an), `from < to` toujours vrai. L'accessibilité clavier est une exigence de premier rang, pas une option : les bornes sont focalisables au tab et ajustables aux flèches.

## User Story

> En tant que visiteur, je veux resserrer, élargir et faire glisser la fenêtre temporelle directement sur la frise, à la souris comme au clavier, afin d'explorer la carte sur la période qui m'intéresse et de partager l'URL exacte de cette vue.

---

## Tâches

- [ ] Rendu de la fenêtre dans `TimelineHook` (calque SVG prévu en #020) : rectangle de fenêtre + deux poignées de borne, zones de hit élargies (minimum 44 px de haut, 12 px de large autour de chaque poignée) pour la souris et le tactile.
- [ ] Geste souris/tactile via Pointer Events (`pointerdown`/`pointermove`/`pointerup` avec `setPointerCapture`) :
  - drag d'une poignée : déplace la borne correspondante, conversion pixel -> année via `time_scale.year`, clamp au domaine et à la largeur minimale (la borne opposée ne bouge jamais pendant un resize) ;
  - drag du corps : translation des deux bornes à largeur constante en années, blocage net aux bords du domaine (pas de compression silencieuse de la fenêtre) ;
  - curseurs adaptés (`ew-resize` sur les poignées, `grab`/`grabbing` sur le corps).
- [ ] Debounce 150 ms : pendant le geste, rendu local uniquement ; `pushEvent("select_time_window", {from, to})` déclenché 150 ms après le dernier mouvement (et systématiquement au `pointerup`).
- [ ] Côté LiveView Explore (#018) :
  - `handle_event("select_time_window", ...)` : validation stricte (entiers, `from < to`, clamp au domaine `TimeScale`, largeur minimale) ; toute payload invalide est rejetée sans crash ni application partielle ;
  - mise à jour des assigns et `push_patch` vers l'URL avec `from`/`to` (format d'URL défini en #018, années astronomiques) ;
  - `handle_params` : lecture et validation des params d'URL, puis `push_event("time_window_changed", %{from, to})` vers le hook.
- [ ] Garde anti-écho : le hook mémorise la dernière fenêtre qu'il a poussée et ignore un `time_window_changed` identique (comparaison des bornes) ; documenter le mécanisme en commentaire.
- [ ] Rafraîchissement des données après debounce : la mise à jour de la fenêtre déclenche le re-fetch de l'histogramme (#020) et la carte (#015/#018) reçoit la nouvelle fenêtre par le flux d'état existant d'Explore ; aucun fetch pendant le geste.
- [ ] Accessibilité clavier :
  - poignées focalisables (`tabindex="0"`), ordre de tabulation : borne gauche, corps, borne droite ;
  - `role="slider"` sur chaque poignée avec `aria-valuemin`, `aria-valuemax`, `aria-valuenow` et `aria-valuetext` formaté via `time_format` (#020) ; le corps porte un `aria-label` décrivant la fenêtre ;
  - flèches gauche/droite : ajustement de l'élément focalisé d'un pas adaptatif (pas de graduation courant fourni par `ticks`), Shift+flèche : pas x10 ; sur le corps, les flèches translatent la fenêtre ;
  - les ajustements clavier passent par le même debounce et la même validation que la souris.
- [ ] Respect de `prefers-reduced-motion` : aucune animation de repositionnement si le média est actif, sinon transition courte.
- [ ] `destroyed()` : retirer les listeners Pointer Events et clavier ajoutés par cette issue (en plus du cleanup de #020).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : logique de contrainte extraite en fonctions pures du hook (testables sous node:test) : resize d'une borne dans le domaine, translation du corps, conversions pixel <-> année cohérentes avec `time_scale`.
- [ ] **Edge case** : translation du corps contre un bord du domaine : la fenêtre s'arrête au bord et conserve sa largeur.
- [ ] **Edge case** : resize jusqu'à la largeur minimale : la borne s'arrête à `borne_opposée +/- largeur_min`, jamais de croisement `from >= to`.
- [ ] **Error case** : `handle_event("select_time_window")` avec payload hostile (chaînes non numériques, années hors domaine, `from > to`, champs manquants) : état inchangé, pas de crash de la LiveView.
- [ ] **Limit case** : fenêtre égale au domaine complet, fenêtre à la largeur minimale exacte, bornes exactement sur min/max du domaine.

### Property-based tests

- [ ] **Property (invariant de fenêtre)** : pour toute séquence de gestes générée (resize/translation de deltas arbitraires), les invariants tiennent toujours : `min_domaine <= from < to <= max_domaine` et `to - from >= largeur_min` (StreamData sur la logique pure ; en JS, générateur simple maison sous node:test).

### Doctests

- [ ] **Doctest** : fonction de validation/clamp de fenêtre côté Elixir (module de validation d'Explore ou de `TimeScale`) avec un exemple de clamp et un exemple de rejet.

### Tests d'intégration

- [ ] **Intégration (LiveViewTest)** : `select_time_window` valide -> assigns mis à jour, URL patchée avec `from`/`to` ; payload invalide -> assigns inchangés.
- [ ] **Intégration (LiveViewTest)** : montage avec `?from=&to=` dans l'URL -> `push_event("time_window_changed", ...)` émis avec les bornes validées (assert sur l'événement poussé).
- [ ] **Intégration (LiveViewTest)** : navigation retour (nouveau `handle_params`) resynchronise la fenêtre.

### Tests end-to-end

- [ ] **E2E (Wallaby)** : geste complet au navigateur : charger Explore, saisir la poignée droite et la déplacer (actions souris Wallaby ou script de Pointer Events synthétiques), vérifier après debounce que l'URL contient les nouvelles bornes et que la carte a rafraîchi ses données ; puis faire glisser le corps et vérifier la conservation de la largeur.
- [ ] **E2E (Wallaby)** : parcours clavier : tab jusqu'à la poignée gauche, flèches, vérification de l'`aria-valuenow` et de l'URL après debounce.
- [ ] **E2E (Wallaby)** : ouvrir directement une URL partagée avec fenêtre : la frise affiche la fenêtre attendue.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/js/hooks/timeline.js` (extension : calque fenêtre, gestes, clavier)
  - `assets/js/lib/time_window.js` (nouveau : logique pure de contraintes, testable sous Node)
  - `assets/js/test/time_window.test.js` (nouveau)
  - `lib/amanogawa_web/live/explore_live.ex` (#018 : `handle_event`, `handle_params`, validation)
  - `test/amanogawa_web/live/explore_live_test.exs` (extension)
  - `test/e2e/timeline_window_test.exs` (nouveau, Wallaby)
- **Documentation de référence** : ADR 0005 (état LiveView, gestes hook), `.claude/rules/liveview.md` (debounce 150 ms, noms d'événements explicites, validation des payloads, cleanup), issue #018 (format d'URL d'Explore), issue #019 (`time_scale.js`), issue #020 (structure du hook, `time_format`), WAI-ARIA slider pattern (https://www.w3.org/WAI/ARIA/apg/patterns/slider/).
- **Compétences requises** : Pointer Events et capture de pointeur, patterns ARIA slider, LiveView `push_patch`/`handle_params`/`push_event`, Wallaby (interactions souris et clavier).
- **Points d'attention** :
  - Extraire la logique de contraintes dans `time_window.js` pur : c'est ce qui rend le geste testable sans navigateur ; le hook ne fait que brancher les événements DOM sur cette logique.
  - Anti-écho obligatoire : sans garde, `pushEvent` -> `push_patch` -> `handle_params` -> `push_event` -> repositionnement -> risque de boucle ou de saut visuel pendant un geste en cours. Ignorer aussi tout `time_window_changed` reçu pendant un `pointerdown` actif (le geste de l'utilisateur a priorité).
  - Le debounce est client (règle LiveView) : ne pas ajouter de debounce serveur en plus.
  - `select_time_window` est le nom d'événement imposé par les conventions (verbe explicite, déjà cité dans `.claude/rules/liveview.md`).
  - Wallaby et le drag : si les actions souris natives sont insuffisantes pour les Pointer Events, dispatcher des événements synthétiques via `execute_script` ; le critère du test est le résultat observable (URL, rendu), pas la mécanique interne.
  - Les tests E2E touchent le navigateur et la base : `async: false` pour ces modules.
