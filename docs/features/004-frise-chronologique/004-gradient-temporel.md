# Issue #022 -- Gradient temporel partagé (carte, frise, légende)

**Feature :** F04 -- Frise chronologique
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #021, #015

---

## Contexte

Dernière brique de la frise : le gradient temporel bleu -> rouge qui encode la position d'un événement dans la fenêtre sélectionnée. Un événement daté au début de la fenêtre est bleu, un événement daté à la fin est rouge, avec interpolation continue entre les deux. Ce code couleur apparaît à trois endroits qui doivent être rigoureusement identiques : les marqueurs de la carte (MapHook, #015), la fenêtre de la frise (TimelineHook, #020/#021) et une légende UI qui explicite la correspondance couleur -> date.

La règle Tailwind du projet impose une source unique : les deux couleurs extrêmes sont des tokens CSS (`--time-start-color`, `--time-end-color`) définis dans le thème Tailwind v4 (`@theme` de `app.css`), avec des valeurs adaptées à chaque thème (clair et sombre) et des contrastes vérifiés. Tout le reste (util JS, expressions MapLibre, dégradé CSS de la légende) dérive de ces tokens : aucun code couleur en dur ailleurs.

Le point délicat est l'identité d'interpolation entre trois moteurs de rendu différents (expressions MapLibre, JS dans la frise, `linear-gradient` CSS). La convention retenue et documentée : la teinte d'un événement est fonction de son année normalisée LINÉAIREMENT dans la fenêtre (`(year - from) / (to - from)`, clampée dans [0,1]), pas de sa position symlog ; l'interpolation des couleurs se fait canal par canal en sRGB, ce qui est le comportement commun de `["interpolate", ["linear"], ...]` de MapLibre, d'une interpolation RGB manuelle en JS et d'un `linear-gradient` CSS par défaut.

Enfin, l'expérience pendant le drag de la fenêtre (#021) doit rester fluide : les couleurs et opacités se mettent à jour immédiatement (opérations de style, peu coûteuses), mais aucun re-fetch de données n'a lieu avant le debounce.

## User Story

> En tant que visiteur, je veux que la couleur des marqueurs reflète la position de chaque événement dans la période sélectionnée, avec une légende lisible, afin de distinguer d'un coup d'oeil le début et la fin de la période sur la carte.

---

## Tâches

- [ ] Définir les tokens dans `assets/css/app.css` (`@theme`) : `--time-start-color` (bleu) et `--time-end-color` (rouge), avec surcharge pour le thème sombre (`prefers-color-scheme: dark`) ; choisir des valeurs vérifiées au contraste (voir plan de tests) sur les fonds de carte clair et sombre (#005) et les fonds d'UI des deux thèmes.
- [ ] Créer `assets/js/lib/time_gradient.js` (module pur, sans dépendance) :
  - `readGradientTokens(element)` : lit les deux tokens via `getComputedStyle` et les parse en RGB ;
  - `colorFor(t, tokens)` : interpolation sRGB canal par canal pour `t` dans [0,1] (clamp), retourne une couleur CSS ;
  - `normalizeYear(year, from, to)` : normalisation linéaire clampée ;
  - `mapLibreColorExpression(from, to, tokens)` : construit l'expression MapLibre `["interpolate", ["linear"], <year normalisé>, 0, start, 1, end]` à partir des MÊMES tokens ;
  - documenter en tête de fichier la convention (normalisation linéaire en année, interpolation sRGB) : ce commentaire fait foi pour les trois rendus.
- [ ] MapHook (#015) : appliquer `mapLibreColorExpression` à la couleur des marqueurs (layer circle), la propriété `year` étant déjà présente dans les features GeoJSON (#014) ; à chaque changement de fenêtre, mettre à jour l'expression via `setPaintProperty` (pas de rechargement de source).
- [ ] TimelineHook : teinter la fenêtre (#021) avec le même dégradé (dégradé SVG ou CSS construit depuis les tokens) pour que la frise serve elle-même de rappel de légende.
- [ ] Légende UI : function component `AmanogawaWeb.Components.TimeLegend` (heex) : barre en `linear-gradient(to right, var(--time-start-color), var(--time-end-color))`, bornes libellées via `Amanogawa.Atlas.format_axis_year/2` (#020), intégrée au template d'Explore et mise à jour quand la fenêtre change (assigns).
- [ ] Réactivité au thème : le MapHook et le TimelineHook relisent les tokens et réappliquent les styles quand `prefers-color-scheme` change (listener `matchMedia`, retiré dans `destroyed()`).
- [ ] Fluidité pendant le drag (#021) : pendant le geste, mise à jour immédiate de l'expression de couleur et transition d'opacité sur les marqueurs sortant/entrant de la fenêtre (transitions de paint MapLibre) ; AUCUN re-fetch de données avant le debounce de 150 ms ; respecter `prefers-reduced-motion` (transitions à durée nulle).
- [ ] Vérification des contrastes : test automatisé calculant les ratios WCAG des deux tokens, dans les deux thèmes, contre les fonds correspondants (fond de carte et fond d'UI) : ratio >= 3:1 exigé pour les composants graphiques (WCAG 1.4.11), et >= 4.5:1 pour les textes de la légende par rapport à leur fond.
- [ ] Documenter la palette retenue et la convention d'interpolation dans `.claude/memory/` (fichier de mémoire du design ou `domain-model.md`).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `colorFor(0)` retourne exactement `--time-start-color`, `colorFor(1)` exactement `--time-end-color`, `colorFor(0.5)` la moyenne canal par canal (node:test sur `time_gradient.js` avec tokens injectés).
- [ ] **Happy path** : `mapLibreColorExpression` produit une expression MapLibre valide dont les stops 0 et 1 portent les couleurs des tokens et dont la sous-expression de normalisation correspond à `(year - from) / (to - from)`.
- [ ] **Edge case** : `normalizeYear` clampe les années hors fenêtre (avant `from` -> 0, après `to` -> 1) ; fenêtre dégénérée `from == to` gérée sans division par zéro (comportement documenté).
- [ ] **Error case** : `readGradientTokens` sur un élément sans tokens définis lève une erreur explicite (échec bruyant plutôt que gradient noir silencieux).
- [ ] **Limit case** : contrastes WCAG : ratios des tokens contre les fonds clair et sombre >= 3:1 (composants graphiques) et textes de légende >= 4.5:1, calculés dans un test (échec du test si une future retouche de palette casse l'accessibilité).

### Property-based tests

- [ ] **Property (monotonie par canal)** : pour `t1 < t2` dans [0,1], chaque canal de `colorFor` évolue de façon monotone entre les deux couleurs extrêmes (générateur simple sous node:test ; pas de StreamData ici, la logique est purement JS).

### Doctests

- [ ] **Doctest** : non applicable côté Elixir : `TimeLegend` est un composant heex sans logique pure nouvelle (le formatage vient de #020, déjà couvert par doctests).

### Tests d'intégration

- [ ] **Intégration (LiveViewTest)** : Explore rend la légende avec les bornes formatées de la fenêtre courante ; après `select_time_window`, les libellés de la légende sont mis à jour.
- [ ] **Intégration (LiveViewTest)** : la légende référence bien les custom properties (classes/styles présents dans le HTML rendu), aucune couleur en dur.

### Tests end-to-end

- [ ] **E2E (Wallaby)** : charger Explore avec une fenêtre connue, vérifier via `execute_script` que la couleur calculée d'un marqueur au début de fenêtre correspond au token de départ et qu'un marqueur en fin de fenêtre correspond au token de fin (lecture des paint properties MapLibre ou des couleurs calculées).
- [ ] **E2E (Wallaby)** : pendant un drag de fenêtre, aucun appel réseau vers `/api/events` avant le debounce (interception/comptage des requêtes via script), et les couleurs sont déjà mises à jour.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/css/app.css` (tokens `--time-start-color`, `--time-end-color`, variantes sombres)
  - `assets/js/lib/time_gradient.js` (nouveau)
  - `assets/js/test/time_gradient.test.js` (nouveau)
  - `assets/js/hooks/map.js` (#015 : expression de couleur, transitions d'opacité, listener de thème)
  - `assets/js/hooks/timeline.js` (#020/#021 : teinte de la fenêtre)
  - `lib/amanogawa_web/components/time_legend.ex` (nouveau)
  - template de la LiveView Explore (#018 : intégration de la légende)
  - `test/amanogawa_web/components/time_legend_test.exs`, `test/amanogawa_web/live/explore_live_test.exs` (extension), `test/e2e/time_gradient_test.exs` (nouveaux)
  - `.claude/memory/` (palette et convention documentées)
- **Documentation de référence** : `.claude/rules/tailwind.md` (palette du gradient en custom properties, source unique, dark mode), ADR 0005 (expressions MapLibre pilotées par données), issues #014/#015 (propriété `year` des features GeoJSON, layers), #020 (formatteur), #021 (drag et debounce), spécification MapLibre `interpolate` (https://maplibre.org/maplibre-style-spec/expressions/#interpolate), WCAG 2.1 1.4.3 et 1.4.11 (https://www.w3.org/TR/WCAG21/).
- **Compétences requises** : expressions MapLibre (interpolate, setPaintProperty, paint transitions), custom properties CSS et thèmes, calcul de ratios de contraste WCAG, function components Phoenix.
- **Points d'attention** :
  - Source unique absolue : si une couleur du gradient apparaît en dur ailleurs que dans `app.css`, c'est un défaut à corriger immédiatement (règle Tailwind du projet).
  - La normalisation est linéaire en années dans la fenêtre, PAS symlog : à fenêtre courte l'écart est négligeable, à fenêtre large c'est un choix assumé (la couleur encode la position dans la période sélectionnée, l'axe encode la position historique) ; ne pas "corriger" l'un avec l'autre.
  - MapLibre ne lit pas les custom properties CSS : les couleurs doivent être résolues en JS (`getComputedStyle`) au moment de construire l'expression, et re-résolues au changement de thème.
  - Les dégradés CSS interpolent en sRGB par défaut : ne pas spécifier d'espace d'interpolation moderne (`in oklch`) sous peine de diverger de MapLibre et du JS.
  - Événements sans année dans la fenêtre affichée (bords, clamp) : la couleur clampe aux extrêmes, l'opacité gère la sortie de fenêtre ; pas de troisième couleur "hors fenêtre".
  - `prefers-reduced-motion` : transitions d'opacité à durée nulle, jamais de suppression de l'information de couleur.
