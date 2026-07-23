# Issue #005 -- Fond de carte vectoriel et MapHook minimal

**Feature :** F01 -- Fondations
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #004

---

## Contexte

Cette issue apporte la preuve de bout en bout du pipeline front : MapLibre GL JS vendoré via npm (pas de CDN, ADR 0005), un hook LiveView `MapHook` minimal qui affiche une carte du monde vide dans la zone préparée en #004, et le choix, tranché ici, du fond de tuiles vectorielles. La carte n'affiche encore aucune donnée historique : les sources GeoJSON et les interactions arrivent en F03.

### Choix du fond de tuiles vectorielles

Candidats (mémoire `tech-stack.md`, vue d'ensemble F01) : OpenFreeMap (instance publique communautaire servant les tuiles OpenMapTiles de la planète) et Protomaps auto-hébergé (fichier PMTiles unique servi en range requests depuis notre infrastructure). Google et Mapbox sont exclus d'office (éthique, clé API, tracking).

| Critère | OpenFreeMap | Protomaps/PMTiles auto-hébergé |
|---------|-------------|--------------------------------|
| Qualité visuelle | Schéma OpenMapTiles complet (planète entière, POI, labels multilingues), styles matures compatibles (Positron, Liberty, Dark Matter) | Basemap Protomaps plus minimaliste, styles clair/sombre fournis (`@protomaps/basemaps`), moins riche en détails |
| Conditions d'usage | Gratuit, sans clé API, sans limite d'usage déclarée, projet open source financé par dons, pas de cookies ni de suivi des utilisateurs ; attribution OpenStreetMap requise (ODbL) | Aucune condition externe : le fichier est chez nous ; attribution OpenStreetMap requise (ODbL) |
| Coût | Nul | Stockage du build planétaire (ordre de grandeur 100 GB et plus) plus bande passante sur le VPS, dès le MVP |
| Self-hosting | Possible (le projet publie son code et ses images de tuiles) mais lourd : infrastructure dédiée, centaines de GB | Natif et simple : un fichier statique, un serveur HTTP avec range requests, mises à jour à orchestrer nous-mêmes |
| Risque principal | Dépendance à un service communautaire sans SLA (disponibilité) | Infrastructure supplémentaire à opérer dès F01 |

**Décision : OpenFreeMap pour le MVP.** Justification :

- Coût nul et zéro infrastructure supplémentaire, cohérent avec le refus d'infrastructure prématurée acté en ADR 0007 (même logique que le report des tuiles vectorielles générées).
- Conditions d'usage explicites et alignées avec l'éthique du projet (ADR 0008) : pas de clé, pas de compte, pas de suivi des utilisateurs, projet lui-même open source. À re-vérifier sur le site officiel au moment de l'implémentation.
- Qualité visuelle supérieure pour une carte monde destinée à porter des données historiques par dessus.
- Le risque de dépendance est mitigé : les styles JSON sont vendorés dans notre dépôt (seuls tuiles, glyphes et sprites sont distants), le hook est agnostique du fournisseur, et la bascule vers Protomaps/PMTiles auto-hébergé reste ouverte en F06 (déploiement) si l'exigence d'auto-hébergement complet ou la disponibilité le justifient. Cette porte de sortie est documentée dans le README par cette issue.

## User Story

> En tant que visiteur, je veux voir une carte du monde interactive (déplacement, zoom) au fond sobre, adaptée à mon thème clair ou sombre, afin de vérifier que le socle cartographique du projet fonctionne de bout en bout.

---

## Tâches

- [ ] Créer `assets/package.json` et installer `maplibre-gl` en version épinglée (dernière stable, vérifier au moment de l'implémentation). Étendre l'alias `assets.setup` dans `mix.exs` avec l'installation npm (`cmd --cd assets npm install --no-fund --no-audit`) pour que `mix setup` reste la seule commande d'installation. Vérifier que `assets/node_modules/` est bien ignoré (#001).
- [ ] Charger la feuille de style MapLibre : `@import "maplibre-gl/dist/maplibre-gl.css";` dans `assets/css/app.css` si la résolution node_modules fonctionne avec le binaire Tailwind ; sinon copier le fichier en `assets/vendor/maplibre-gl.css` (version notée en commentaire) et l'importer depuis là.
- [ ] Vendorer les styles de carte dans le dépôt :
  - `assets/vendor/map-styles/light.json` : dérivé d'un style neutre clair compatible OpenMapTiles (base Positron), sources pointant vers les tuiles planétaires OpenFreeMap, glyphes et sprites OpenFreeMap ;
  - `assets/vendor/map-styles/dark.json` : dérivé d'un style sombre compatible (base Dark Matter), mêmes sources ;
  - dans les deux : attribution `© OpenStreetMap contributors` et OpenFreeMap, palette ajustée pour rester discrète sous les futures données historiques (tokens de #004 comme référence visuelle), en-tête de commentaire impossible en JSON donc origine et licence des styles documentées dans le README.
- [ ] Créer le hook `assets/js/hooks/map_hook.js` (vanilla JS, un seul concern) :
  - `mounted()` : instancier `maplibregl.Map` sur `this.el` (style clair ou sombre selon `matchMedia("(prefers-color-scheme: dark)")`, centre `[0, 20]`, zoom initial faible affichant le monde entier, `attributionControl` visible et compact) ;
  - écouter le changement de `prefers-color-scheme` et basculer via `setStyle` ;
  - respecter `prefers-reduced-motion` (réduire ou annuler les animations d'easing MapLibre) ;
  - `destroyed()` : `map.remove()` et retrait du listener `matchMedia` (aucune fuite, règle `.claude/rules/liveview.md`).
- [ ] Enregistrer le hook dans `assets/js/app.js` (`hooks: { MapHook }`) et poser le conteneur dans le rendu de `HomeLive` : `id` stable, `phx-hook="MapHook"`, `phx-update="ignore"`, occupant toute la zone carte de #004.
- [ ] Étendre la CSP (#004) : ajouter l'origine des tuiles OpenFreeMap à `connect-src` (tuiles, glyphes et sprites sont récupérés en fetch par MapLibre). Aucune autre directive ne doit changer.
- [ ] Documenter dans le README : la décision de fond de carte (résumé du tableau ci-dessus et lien vers cette issue), l'attribution obligatoire, la procédure de bascule future vers PMTiles (styles vendorés à repointer, CSP à ajuster, hook inchangé), et le budget JS constaté après build (MapLibre environ 230 KB gzip attendus, aucune autre dépendance front ajoutée).
- [ ] Vérifier en navigateur : carte affichée en clair et en sombre, déplacement et zoom fluides, aucune violation CSP, aucune erreur console, attribution visible.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : test Elixir qui lit `assets/vendor/map-styles/light.json` et `dark.json`, les décode avec `Jason.decode!/1` et vérifie la structure minimale d'un style MapLibre (clé `"version" => 8`, `sources` non vide, `layers` non vide, `glyphs` présent).
- [ ] **Edge case** : test qui extrait toutes les URLs distantes des deux styles (`sources`, `glyphs`, `sprite`) et vérifie qu'elles appartiennent exclusivement aux origines autorisées par la CSP (cohérence styles/CSP garantie par le test).
- [ ] **Error case** : le test de structure échoue clairement si un style vendoré est invalide ou vide (protection contre une régression lors d'une mise à jour manuelle des styles).
- [ ] **Limit case** : les deux styles déclarent une attribution non vide contenant OpenStreetMap (l'obligation ODbL ne peut pas disparaître silencieusement).

### Property-based tests (si applicable)

- [ ] Non applicable : aucune logique de transformation de données côté Elixir.

### Doctests (si applicable)

- [ ] Non applicable.

### Tests d'intégration

- [ ] **Intégration** (LiveViewTest) : le rendu de `HomeLive` contient l'élément avec `phx-hook="MapHook"` et `phx-update="ignore"` et un id stable (contrat DOM du hook).
- [ ] **Intégration** (test du plug CSP, complément de #004) : `connect-src` contient l'origine des tuiles OpenFreeMap en plus de `'self'` et de l'origine WebSocket.
- [ ] **Intégration** (build) : `mix assets.build` réussit avec l'import de `maplibre-gl` et des styles JSON ; couvert à chaque exécution de `mix precommit` et en CI (#003), l'alias `assets.setup` étendu étant lui aussi exercé en CI si le cache npm est absent.

### Tests end-to-end (si applicable)

- [ ] Non applicable à ce stade : aucune infrastructure navigateur (Wallaby) n'est installée, elle arrive avec le parcours critique de F03. Vérification manuelle documentée dans la PR : carte visible en clair et sombre, pan et zoom, redimensionnement de fenêtre, navigation LiveView aller-retour sans fuite (le hook se détruit et se recrée proprement), console sans erreur ni violation CSP.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/package.json` (créer) et `assets/package-lock.json` (généré, commité)
  - `assets/js/hooks/map_hook.js` (créer)
  - `assets/js/app.js` (enregistrement du hook)
  - `assets/vendor/map-styles/light.json`, `assets/vendor/map-styles/dark.json` (créer)
  - `assets/css/app.css` (import CSS MapLibre) ou `assets/vendor/maplibre-gl.css` (repli)
  - `lib/amanogawa_web/live/home_live.ex` (conteneur du hook)
  - `lib/amanogawa_web/plugs/content_security_policy.ex` (origine des tuiles)
  - `mix.exs` (alias `assets.setup`)
  - `test/amanogawa_web/map_styles_test.exs`, `test/amanogawa_web/live/home_live_test.exs`, `test/amanogawa_web/plugs/content_security_policy_test.exs` (créer ou compléter)
  - `README.md` (décision, attribution, bascule PMTiles, budget JS)
- **Documentation de référence** : ADR 0005 (hooks vanilla, pas de CDN), ADR 0007 (refus d'infrastructure prématurée), ADR 0008 (éthique), `.claude/rules/liveview.md` (cycle de vie des hooks), `.claude/memory/tech-stack.md`, documentation MapLibre GL JS (Map, setStyle, spécification de style v8), site OpenFreeMap (conditions d'usage, URLs des tuiles et styles), documentation Protomaps/PMTiles (pour la section bascule du README).
- **Compétences requises** : hooks LiveView (mounted/destroyed, phx-update="ignore"), MapLibre GL JS, spécification de style MapLibre v8, npm dans le pipeline esbuild de Phoenix, CSP.
- **Points d'attention** :
  - `phx-update="ignore"` est obligatoire sur le conteneur : sans lui, un re-render LiveView détruit le canvas MapLibre.
  - `destroyed()` doit libérer la carte ET le listener `matchMedia` : les fuites de hooks sont invisibles jusqu'à la navigation répétée.
  - Aucun CDN, aucune URL de style distante : seuls tuiles, glyphes et sprites sont distants, tout le reste est dans le dépôt.
  - Ne pas installer d'autre paquet npm (pas de `pmtiles` tant que la bascule n'est pas décidée, d3 arrive en F04).
  - Le style doit rester discret : la carte est un fond, les données historiques (F03) sont le sujet.
  - `setStyle` recharge le style entier : acceptable ici (aucune source de données applicative encore) ; F03 devra re-poser ses sources après un changement de thème, le noter en commentaire dans le hook.
  - Si l'instance publique OpenFreeMap est indisponible pendant le développement, la carte doit rester fonctionnelle (fond vide, pas de crash du hook) : MapLibre gère les erreurs de tuiles nativement, ne rien ajouter de défensif.
