# Issue #004 -- Layout racine, design tokens Tailwind et CSP

**Feature :** F01 -- Fondations
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #001

---

## Contexte

L'interface d'Amanogawa est une carte plein écran surmontée d'une topbar minimale, avec la frise chronologique ancrée en bas (ADR 0005). Cette issue pose cette structure d'écran dans le layout racine, définit les design tokens Tailwind v4 en configuration CSS-first (`.claude/rules/tailwind.md`), met en place le dark mode via `prefers-color-scheme`, et installe la CSP stricte exigée par l'éthique du projet (ADR 0008 : zéro tracking, zéro script tiers).

Deux points structurants :

- Le gradient temporel (bleu pour le passé lointain, rouge pour le présent) est LA signature visuelle du projet. Ses couleurs sont définies une seule fois comme variables CSS (`--time-start-color`, `--time-end-color`) et partagées par la frise (hook d3), les marqueurs de la carte (expressions MapLibre) et la légende : source unique de vérité.
- Phoenix 1.8 génère une base daisyUI (fichiers vendorés dans `assets/vendor/`, directives `@plugin` dans `app.css`, classes daisyUI dans `core_components.ex`, toggle de thème). La règle du projet est : pas de bibliothèque de composants, dark mode par `prefers-color-scheme` sans toggle. Cette issue retire donc daisyUI et adapte les composants générés.

La CSP définie ici anticipe l'issue #005 : MapLibre GL JS exige des workers `blob:` et des images `data:`/`blob:`. L'hôte de tuiles sera ajouté à `connect-src` en #005.

## User Story

> En tant que visiteur, je veux une page d'accueil structurée (topbar, zone carte plein écran, emplacement de frise) respectant mon thème clair ou sombre, afin de disposer d'une interface cohérente et sobre avant même l'arrivée des données.

---

## Tâches

- [ ] Retirer daisyUI : supprimer `assets/vendor/daisyui.js` et `assets/vendor/daisyui-theme.js`, retirer les directives `@plugin` correspondantes de `assets/css/app.css`, supprimer le toggle de thème généré (layout et JS éventuel), remplacer dans `lib/amanogawa_web/components/core_components.ex` les classes daisyUI par des utilitaires Tailwind s'appuyant sur les tokens définis ci-dessous. Ne conserver que les composants réellement utilisés (flash, bouton, input de base) ; supprimer le reste plutôt que de maintenir du code mort.
- [ ] Définir les design tokens dans `assets/css/app.css` via `@theme` (Tailwind v4, CSS-first, aucune valeur arbitraire dans les templates) :
  - palette : fond, surface, bordure, texte principal, texte secondaire, accent ;
  - typographie : pile de polices système (aucune police distante, CSP oblige ; une police vendorée pourra arriver plus tard), tailles et graisses de la topbar et des textes courants ;
  - tokens temporels reliés aux variables partagées (voir tâche suivante), par exemple `--color-time-start: var(--time-start-color)` et `--color-time-end: var(--time-end-color)` pour disposer des utilitaires Tailwind correspondants.
- [ ] Déclarer les variables partagées du gradient temporel sur `:root` : `--time-start-color` (bleu) et `--time-end-color` (rouge), avec un commentaire indiquant qu'elles sont lues à l'exécution par les hooks JS (`getComputedStyle`) et qu'elles ne doivent jamais être dupliquées ailleurs.
- [ ] Dark mode : bloc `@media (prefers-color-scheme: dark)` redéfinissant les variables de palette (et, si besoin de lisibilité, les variantes sombres des couleurs temporelles). Aucun toggle, aucune classe `dark` : le système décide.
- [ ] Respecter `prefers-reduced-motion` : bloc média désactivant transitions et animations CSS.
- [ ] Layout racine `lib/amanogawa_web/components/layouts/root.html.heex` : `<html lang="fr">`, métas standard, structure plein écran sans défilement (`100dvh`) composée de trois zones : topbar minimale (nom Amanogawa, emplacements pour liens Sources et À propos), zone carte occupant tout l'espace restant (conteneur destiné à recevoir la carte en #005), bandeau bas de hauteur fixe réservé à la frise (vide pour l'instant, avec identifiant stable).
- [ ] Adapter `AmanogawaWeb.Layouts.app/1` à cette structure (flash conservé, wrappers générés superflus retirés).
- [ ] Page d'accueil coquille : créer `AmanogawaWeb.HomeLive` monté sur `/` (assigns statiques uniquement, aucune requête base dans `mount/3`, règle `.claude/rules/liveview.md`), supprimer `PageController`, son template, et le test généré associé. Mettre à jour `router.ex` (`live "/", HomeLive`).
- [ ] CSP stricte : créer le module plug `AmanogawaWeb.Plugs.ContentSecurityPolicy` branché dans le pipeline `:browser` du router (après `put_secure_browser_headers`), construisant l'en-tête `content-security-policy` à partir de l'hôte configuré de l'endpoint :
  - `default-src 'self'`
  - `script-src 'self'`
  - `style-src 'self'`
  - `img-src 'self' data: blob:`
  - `font-src 'self'`
  - `connect-src 'self'` plus l'origine WebSocket explicite (`ws://<host>:<port>` en dev, `wss://<host>` en prod) pour le canal LiveView
  - `worker-src blob:` et `child-src blob:` (workers MapLibre, #005)
  - `frame-ancestors 'none'`, `base-uri 'self'`, `form-action 'self'`
- [ ] Vérifier en navigateur : aucune violation CSP en console (LiveView connecté, rechargement live en dev), rendu correct clair et sombre, aucun défilement parasite.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : test du plug CSP (Plug.Test) vérifiant la présence de l'en-tête `content-security-policy` et de chaque directive attendue (`default-src 'self'`, `worker-src blob:`, `frame-ancestors 'none'`, origine WebSocket).
- [ ] **Edge case** : le plug construit l'origine WebSocket à partir de la config d'endpoint (test avec un host non défaut, vérifiant `wss://exemple.test`).
- [ ] **Error case** : aucune directive n'autorise un hôte tiers ni `unsafe-inline`/`unsafe-eval` (assertion négative sur la valeur de l'en-tête).
- [ ] **Limit case** : l'en-tête est présent sur toutes les routes du pipeline `:browser` (au minimum `/`), et absent des routes hors navigateur si elles existent.

### Property-based tests (si applicable)

- [ ] Non applicable : pas de logique de transformation de données.

### Doctests (si applicable)

- [ ] Non applicable : le plug n'a pas d'API publique documentable au delà de `init/1` et `call/2`.

### Tests d'intégration

- [ ] **Intégration** (LiveViewTest) : `live(conn, "/")` monte `HomeLive` sans erreur ; le rendu contient la topbar (texte Amanogawa), le conteneur carte et le conteneur frise identifiés par des ids stables.
- [ ] **Intégration** (ConnTest) : `GET /` répond 200 avec le layout racine (`<html lang="fr">`) et l'en-tête CSP.

### Tests end-to-end (si applicable)

- [ ] Non applicable à ce stade (aucune infrastructure navigateur installée). Vérification manuelle documentée dans la PR : captures clair et sombre, console sans violation CSP, absence de défilement, comportement en fenêtre étroite (mobile).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `assets/css/app.css` (tokens `@theme`, variables `:root`, dark mode, reduced motion, retrait daisyUI)
  - `assets/vendor/daisyui.js`, `assets/vendor/daisyui-theme.js` (supprimer)
  - `lib/amanogawa_web/components/layouts/root.html.heex` (structure d'écran)
  - `lib/amanogawa_web/components/layouts.ex` (fonction `app/1`)
  - `lib/amanogawa_web/components/core_components.ex` (dédaisyfication)
  - `lib/amanogawa_web/live/home_live.ex` (créer)
  - `lib/amanogawa_web/plugs/content_security_policy.ex` (créer)
  - `lib/amanogawa_web/router.ex` (route `live "/"`, plug CSP)
  - `lib/amanogawa_web/controllers/page_controller.ex`, `page_html.ex`, `controllers/page_html/home.html.heex`, `test/amanogawa_web/controllers/page_controller_test.exs` (supprimer)
  - `test/amanogawa_web/plugs/content_security_policy_test.exs`, `test/amanogawa_web/live/home_live_test.exs` (créer)
- **Documentation de référence** : `.claude/rules/tailwind.md`, `.claude/rules/liveview.md`, ADR 0005 (structure carte + frise), ADR 0008 (éthique, CSP), documentation Tailwind v4 (`@theme`), MDN Content-Security-Policy.
- **Compétences requises** : Tailwind v4 CSS-first, layouts et composants Phoenix 1.8, LiveView (mount sans requête), écriture d'un plug, directives CSP.
- **Points d'attention** :
  - `style-src 'self'` interdit les attributs `style=` inline dans les templates HEEx : n'utiliser que des classes. Les styles posés par JavaScript via `element.style` (topbar de progression Phoenix, MapLibre) ne sont pas concernés par cette directive.
  - Si la topbar de progression générée (`assets/vendor/topbar.js`) injecte une balise `<style>`, la remplacer par des styles dans `app.css` ou la configurer autrement : aucune exception `unsafe-inline` n'est acceptée.
  - Les noms `--time-start-color` et `--time-end-color` sont contractuels : les hooks de F03/F04 les liront tels quels.
  - Choisir des couleurs de gradient lisibles sur fond clair ET sombre (contraste WCAG AA sur les deux palettes).
  - `100dvh` plutôt que `100vh` (barres d'interface mobiles).
  - Le conteneur carte doit rester un simple `div` vide ici : le hook arrive en #005.
