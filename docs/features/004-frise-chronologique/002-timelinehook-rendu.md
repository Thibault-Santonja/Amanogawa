# Issue #020 -- TimelineHook : rendu frise + histogramme

**Feature :** F04 -- Frise chronologique
**Priorité :** Haute
**Estimation :** 16h
**Prérequis :** #019

---

## Contexte

Avec l'échelle symlog partagée en place (#019), cette issue construit le rendu visuel de la frise : le hook LiveView `TimelineHook` dessine avec d3 (modules scale/selection/zoom uniquement, ADR 0005) un axe gradué adaptatif et, sous l'axe, un histogramme de densité des événements. La frise est le second pilier de l'interface avec la carte : elle doit donner d'un coup d'oeil la répartition temporelle du corpus (~420 000 événements) et rester lisible du paléolithique à aujourd'hui.

Deux points d'architecture structurent l'issue :

- **Libellés d'axe partagés.** Les graduations affichent des formats adaptés à la profondeur temporelle : "100 ka BP" dans le passé profond, "VIIIe s. av. J.-C." pour l'Antiquité, "1969" pour les années récentes. Ces conventions de formatage sont communes au JS (axe de la frise) et à l'Elixir (formatteur Gettext-ready utilisé par les composants serveur : légende, fiche événement). Elles sont documentées une fois et testées des deux côtés via une fixture partagée, sur le modèle des ancres de #019. L'affichage respecte toujours la précision (ADR 0006) : jamais de faux jour inventé.
- **Histogramme agrégé côté SQL.** Le hook ne reçoit jamais 420 000 événements : il appelle `GET /api/events/histogram?from=&to=&buckets=`, un endpoint JSON dédié (ADR 0005 : les volumes passent par des endpoints, pas par les diffs LiveView) qui agrège les comptes par bucket directement en SQL, les buckets étant découpés en espace symlog (largeur constante en position, donc en pixels) pour s'aligner exactement sur l'axe. Cette issue spécifie et implémente cet endpoint.

La fenêtre temporelle interactive (drag, resize) arrive en #021 : ici la frise est encore statique (rendu, redimensionnement, thèmes), mais sa structure DOM et son API interne doivent anticiper la fenêtre.

## User Story

> En tant que visiteur, je veux voir une frise graduée lisible sur toute la profondeur historique, avec la densité des événements sous l'axe, afin de repérer immédiatement les périodes riches et de savoir où zoomer.

---

## Tâches

- [ ] Spécifier et implémenter l'endpoint histogramme :
  - Route `GET /api/events/histogram` dans le scope API existant (#014).
  - Paramètres : `from` et `to` (années astronomiques entières, bornées au domaine de `TimeScale`, `from < to`), `buckets` (entier 1..200, défaut 100). Validation stricte : tout paramètre invalide retourne 422 avec un JSON d'erreur, jamais de valeur silencieusement corrigée. Mêmes gabarits de validation et rate limiting que l'endpoint events (#014).
  - Contexte : `Amanogawa.Atlas.event_histogram/1` (API publique), requête centralisée dans le module de requêtes du contexte : découpage des bords de buckets via `TimeScale.year/2` (positions équidistantes entre `position(from)` et `position(to)`), agrégation SQL en une seule requête avec `width_bucket` sur la position symlog calculée en fragment (`ln(1 + (max_year - begin_year) / pivot)`), constantes passées en paramètres depuis la MÊME configuration `TimeScale` (jamais de constantes dupliquées en dur dans le SQL).
  - Réponse : `{"from": ..., "to": ..., "buckets": [{"from": y0, "to": y1, "count": n}, ...]}` (bords en années astronomiques, liste dense, buckets vides inclus avec `count: 0`).
  - Cache : `Cache-Control: public, max-age` court + arrondi des bornes demandées aux bords de buckets pour maximiser les hits (stratégie notée dans la vue d'ensemble F04) ; documenter l'arrondi dans le contrôleur.
- [ ] Créer le formatteur Elixir `Amanogawa.Atlas.TimeScale.Format` (exposé via `Amanogawa.Atlas.format_axis_year/2`) et son miroir JS `assets/js/lib/time_format.js`, avec les conventions documentées dans le moduledoc Elixir (qui fait foi) et reprises en commentaire d'en-tête JS :
  - pas de graduation >= 1 000 ans et année <= -10 000 : "N ka BP" (BP = avant 1950, cohérent avec les ticks BP de #019) ;
  - pas >= 100 ans et année < an 1 : siècle en chiffres romains "VIIIe s. av. J.-C." (conversion astronomique -> av. J.-C. : année astronomique -749 = 750 av. J.-C.) ; siècles de notre ère : "XIIe s." ;
  - pas < 100 ans : année seule "1969", et "490 av. J.-C." pour les années négatives ;
  - le format dépend du pas de graduation courant (fourni par `ticks/3` de #019), pas d'un zoom implicite.
- [ ] Créer la fixture partagée `test/support/fixtures/time_scale/labels.json` : cas `{year, step, label}` couvrant chaque régime (ex. -98 050 -> "100 ka BP", -750 -> "VIIIe s. av. J.-C.", -490 -> "490 av. J.-C.", 1969 -> "1969", 1100 -> "XIIe s."), testée par ExUnit et node:test.
- [ ] Créer `assets/js/hooks/timeline.js` (`TimelineHook`) et l'enregistrer dans `assets/js/app.js` :
  - conteneur `<div id="timeline" phx-hook="TimelineHook" phx-update="ignore" data-from=... data-to=...>` ajouté au template de la LiveView Explore ;
  - rendu SVG via d3-selection : axe horizontal, graduations issues de `time_scale.ticks`, libellés via `time_format` ;
  - histogramme en barres/aires discrètes sous l'axe, hauteur normalisée sur le max de la réponse, échelle de hauteur documentée (linéaire ou racine, à trancher à l'implémentation et documenter dans le hook) ;
  - fetch de l'histogramme avec `AbortController` (annulation des requêtes obsolètes), état de chargement discret, gestion d'erreur silencieuse mais visible en console dev.
- [ ] Rendu responsive : largeur suivie par `ResizeObserver`, re-rendu débouncé, nombre de graduations cible proportionnel à la largeur (ex. 1 graduation / 80 px).
- [ ] Dark mode : toutes les couleurs du SVG lues depuis les tokens CSS (custom properties du thème Tailwind v4, F01 #004), aucun code couleur en dur dans le hook ; vérifier le rendu dans les deux thèmes, écoute de `prefers-color-scheme` pour re-render au changement de thème.
- [ ] `destroyed()` : déconnecter le `ResizeObserver`, retirer les listeners (matchMedia), annuler les fetch en cours, vider le conteneur.
- [ ] Respecter `prefers-reduced-motion` pour toute transition de rendu.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `Format.format_axis_year/2` retourne les libellés attendus pour chaque cas de `labels.json` ; idem côté JS (node:test, même fixture).
- [ ] **Happy path** : `event_histogram/1` sur un jeu d'événements connu retourne les comptes attendus par bucket, bords alignés sur `TimeScale.year/2`.
- [ ] **Edge case** : fenêtre sans aucun événement : buckets tous à `count: 0`, liste dense de la bonne longueur.
- [ ] **Edge case** : événements exactement sur un bord de bucket : affectation déterministe documentée (borne inférieure incluse, supérieure exclue, dernier bucket fermé).
- [ ] **Error case** : contrôleur histogram : `from >= to`, années hors domaine, `buckets` hors 1..200 ou non entier -> 422 avec erreur JSON explicite.
- [ ] **Limit case** : `buckets=1` (un seul compte global) et `buckets=200` (borne haute) ; fenêtre égale au domaine complet.

### Property-based tests

- [ ] **Property (conservation)** : pour toute fenêtre et tout nombre de buckets valides, la somme des `count` égale le nombre d'événements dont `begin_year` est dans la fenêtre (StreamData sur fenêtres + jeu d'événements généré).
- [ ] **Property (alignement symlog)** : les bords de buckets retournés sont strictement croissants et leurs positions via `TimeScale.position/2` sont équidistantes (tolérance flottante documentée).

### Doctests

- [ ] **Doctest** : `Format.format_axis_year/2` sur un exemple par régime (ka BP, siècle av. J.-C., année simple).

### Tests d'intégration

- [ ] **Intégration (DataCase)** : cohérence SQL/Elixir : pour un échantillon d'événements insérés en base, le bucket calculé par le fragment SQL correspond au bucket calculé en Elixir via `TimeScale.position/2` (garde-fou contre une divergence de formule).
- [ ] **Intégration (ConnCase)** : `GET /api/events/histogram` happy path : 200, structure JSON conforme, en-têtes de cache présents ; paramètres arrondis aux bords de buckets documentés.
- [ ] **Intégration (LiveViewTest)** : la LiveView Explore rend le conteneur `#timeline` avec `phx-hook="TimelineHook"`, `phx-update="ignore"` et les data-attributes de fenêtre.

### Tests end-to-end

- [ ] **E2E** : parcours critique : charger Explore, vérifier que la frise affiche un axe avec des graduations et un histogramme non vide (présence des noeuds SVG), en thème clair et sombre.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/js/hooks/timeline.js` (nouveau)
  - `assets/js/app.js` (enregistrement du hook)
  - `assets/js/lib/time_format.js` (nouveau)
  - `assets/js/test/time_format.test.js` (nouveau)
  - `lib/amanogawa/atlas/time_scale/format.ex` (nouveau)
  - `lib/amanogawa/atlas.ex` (`event_histogram/1`, `format_axis_year/2`)
  - module de requêtes Atlas existant (#014) : requête histogramme
  - contrôleur API events existant (#014) : action `histogram` + route dans `lib/amanogawa_web/router.ex`
  - template de la LiveView Explore (#018) : conteneur de la frise
  - `test/amanogawa/atlas/time_scale/format_test.exs`, `test/amanogawa/atlas_test.exs`, test ConnCase du contrôleur, `test/support/fixtures/time_scale/labels.json` (nouveaux)
- **Documentation de référence** : ADR 0005 (hooks, volumes via endpoints JSON), ADR 0006 (précision, jamais de faux jour), issue #019 (TimeScale, ticks BP, fixtures partagées), issue #014 (validation et rate limiting des endpoints), `.claude/rules/liveview.md` (hooks, cleanup, debounce), `.claude/rules/tailwind.md` (tokens, dark mode).
- **Compétences requises** : d3-selection (rendu SVG bas niveau), `width_bucket` et fragments Ecto, ResizeObserver, chiffres romains et conventions av. J.-C./BP, LiveViewTest et ConnCase.
- **Points d'attention** :
  - Les constantes symlog du SQL viennent de la configuration `TimeScale` passée en paramètres de requête : toute duplication en dur dans un fragment est un bug de conception (c'est le test de cohérence DataCase qui le garantit).
  - `phx-update="ignore"` obligatoire sur le conteneur : LiveView ne doit jamais toucher au DOM géré par d3.
  - Aucune requête DB dans `mount/3` de la LiveView (règle LiveView) : l'histogramme passe par le endpoint, pas par les assigns.
  - Conversion astronomique -> av. J.-C. : année astronomique `-n` = `n+1` av. J.-C. ; le siècle se calcule sur l'année av. J.-C., pas sur l'année astronomique (source classique d'erreur d'un an, cf. pièges F02).
  - Le hook ne stocke aucune donnée volumineuse dans les assigns LiveView ; l'histogramme vit uniquement dans le hook.
  - Prévoir dès maintenant un groupe SVG dédié (calque) pour la fenêtre de #021 afin d'éviter un refactoring du rendu.
