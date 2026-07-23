# Issue #016 -- Hover card et fiche événement avec lien Wikipedia

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #015 (MapHook affichage des événements), #012 (enrichissement des résumés Wikipedia)

---

## Contexte

Les marqueurs affichés par #015 sont muets. Cette issue ajoute les deux niveaux de lecture prévus par la feature :

1. **Hover card** : au survol d'un marqueur, une bulle affiche le titre, le résumé Wikipedia tronqué, la vignette si disponible, et la mention d'attribution CC BY-SA avec lien vers l'article (obligation de licence, meta-règle 9). Un micro-délai de 150 ms avant affichage évite le clignotement lors des survols en passant.
2. **Fiche événement** : au clic sur un marqueur, le hook pousse la sélection à la LiveView (`pushEvent`), qui ouvre un panneau latéral avec la fiche complète (titre, dates rendues selon leur précision, résumé complet, vignette, attribution) et un bouton vers l'article Wikipedia (`target="_blank" rel="noopener noreferrer"`).

**Décision à trancher ici** : résumés embarqués dans les propriétés GeoJSON de `/api/events`, ou endpoint léger dédié ?

Analyse du poids : une réponse `/api/events` au plafond contient 2000 features. Avec les propriétés minimales de #014 (~100 octets par feature), le payload reste ≈ 200 Ko. Embarquer résumé tronqué + URL de vignette + URL d'article ajoute ≈ 500 à 800 octets par feature, soit plus de 1 Mo supplémentaire par rechargement de viewport, payé à chaque déplacement de carte, pour des données que l'utilisateur ne consultera que pour une poignée d'événements. De plus, seule une minorité du corpus possède un extrait (~17 000 FR, ~29 000 EN sur ~420 000).

**Décision : endpoint léger `GET /api/events/:qid/summary`**, appelé à la demande au survol (après le délai de 150 ms, qui sert aussi de garde anti-rafale), avec cache client par QID dans le hook. L'endpoint est pur et cacheable (Cache-Control possible ensuite, ADR 0007).

Sécurité : les contenus Wikipedia sont affichés en texte brut exclusivement (`extract` texte stocké par #012, jamais `extract_html`) ; côté hook, injection via `textContent` uniquement, jamais `innerHTML` ; côté LiveView, HEEx échappe par défaut, ne jamais utiliser `raw/1` sur ces contenus.

Le panneau latéral est un composant fonction branché sur la LiveView de la page carte existante (#005) ; l'orchestration d'état complète (URL, fenêtre, filtres) arrive en #018.

## User Story

> En tant que visiteur, je veux survoler un marqueur pour lire un résumé attribué, puis ouvrir une fiche détaillée avec un lien vers l'article Wikipedia, afin de comprendre un événement sans quitter la carte.

---

## Tâches

- [ ] Ajouter `Amanogawa.Atlas.get_event_summary/1` à l'API publique du contexte : reçoit un QID, retourne `{:ok, summary}` ou `{:error, :not_found}` ; `summary` contient `qid`, `label` (fr, repli en), `extract` (fr, repli en, texte brut), `thumbnail_url`, `wiki_url` (fr, repli en), `extract_language` et `fetched_at` (pour l'attribution).
- [ ] Ajouter l'action `summary` au contrôleur API events : route `GET /api/events/:qid/summary`, validation stricte du format QID (`^Q\d+$`, longueur bornée) avant tout accès base (400 si invalide, 404 si inconnu), réponse JSON plate, rate limiting Hammer du pipeline `:api` (déjà en place via #014).
- [ ] Créer `assets/js/map/hover_card.js` : composant DOM de la bulle (élément positionné en absolu dans le conteneur carte, `aria-hidden` quand masqué) ; rendu exclusivement via `textContent` et attributs contrôlés ; contenu : titre, extrait tronqué (≈200 caractères, coupure sur mot, ellipse), vignette (`<img>` avec `alt`, seulement si `thumbnail_url` présent), mention « Texte : Wikipédia, CC BY-SA 4.0 » avec lien vers l'article.
- [ ] Brancher le survol dans `MapHook` : `mousemove`/`mouseleave` sur le layer `events-circles` ; au survol, timer de 150 ms avant affichage (annulé si le curseur quitte le marqueur) ; fetch du résumé via `/api/events/:qid/summary` avec cache client `Map` QID vers résumé et AbortController ; curseur `pointer` sur les marqueurs ; masquage immédiat au `mouseleave`.
- [ ] Au clic sur un marqueur : `pushEvent("select_event", {qid})` vers la LiveView ; le hook n'ouvre rien lui-même.
- [ ] Côté LiveView de la page carte : `handle_event("select_event", %{"qid" => qid}, socket)` valide le format du QID (payload client jamais fiable), charge l'événement via `Amanogawa.Atlas` (jamais dans `mount/3`), assigne la sélection, affiche le panneau ; QID invalide ou inconnu : sélection ignorée sans crash de la vue.
- [ ] Créer le composant fonction `AmanogawaWeb.Components.EventPanel` : panneau latéral avec titre, dates formatées selon la précision (précision 7 rend « VIIIe siècle av. J.-C. », jamais une fausse date au 1er janvier), extrait complet, vignette, attribution CC BY-SA, bouton « Lire sur Wikipédia » (`target="_blank" rel="noopener noreferrer"`), bouton de fermeture (`handle_event("deselect_event", ...)`).
- [ ] À la sélection et à la désélection, pousser vers le hook `push_event(socket, "event_selected", %{qid: qid})` et `"event_deselected"` : interface consommée par #017 (lignes de relations) ; le hook les ignore proprement tant que #017 n'est pas implémentée.
- [ ] Nettoyage dans `destroyed()` : timer de survol, fetch en cours, élément DOM de la bulle, listeners de layer.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** (DataCase) : `get_event_summary/1` retourne le résumé complet d'un événement avec extrait fr et vignette.
- [ ] **Edge case** (DataCase) : repli en quand label ou extrait fr absents ; événement sans extrait (résumé retourné avec `extract` nil, la bulle affiche alors titre seul) ; événement sans vignette.
- [ ] **Error case** (DataCase) : QID inconnu retourne `{:error, :not_found}`.
- [ ] **Limit case** : QID au format hostile (`Q1' OR 1=1`, chaîne de 10 000 caractères, `../../etc/passwd`) rejeté par la validation avant tout accès base.
- [ ] **Happy path** (node:test) : troncature d'extrait à ≈200 caractères avec coupure sur mot et ellipse ; chaîne courte inchangée ; chaîne vide gérée.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour toute chaîne générée, la validation de QID n'accepte que le motif `^Q\d+$` borné, et ne lève jamais d'exception.

### Doctests (si applicable)

- [ ] **Doctest** : fonction pure de formatage de date selon la précision utilisée par `EventPanel` (exemples : précision 7 en siècle, précision 9 en année, année négative en « av. J.-C. »).

### Tests d'intégration

- [ ] **Intégration** (ConnCase) : `GET /api/events/Q46335/summary` retourne 200 avec les champs attendus ; QID inconnu 404 ; QID invalide 400 ; contenu strictement JSON (pas de HTML).
- [ ] **Intégration** (LiveViewTest) : `select_event` avec QID valide affiche le panneau (titre, attribution, lien avec `rel="noopener noreferrer"` et `target="_blank"`) ; extrait contenant `<script>alert(1)</script>` rendu échappé dans le HTML ; `deselect_event` ferme le panneau ; QID invalide n'altère pas la vue ; `assert_push_event` sur `event_selected` et `event_deselected`.

### Tests end-to-end (si applicable)

- [ ] **E2E** : survoler un marqueur, vérifier l'apparition de la bulle avec titre et mention CC BY-SA ; cliquer, vérifier l'ouverture du panneau et l'URL Wikipedia du bouton ; fermer le panneau.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/atlas.ex` (fonction `get_event_summary/1`)
  - `lib/amanogawa_web/controllers/api/event_controller.ex` (action `summary`), `lib/amanogawa_web/router.ex` (route)
  - `lib/amanogawa_web/components/event_panel.ex`
  - LiveView de la page carte (créée en #005) : `handle_event` sélection/désélection, assigns du panneau
  - `assets/js/hooks/map.js`, `assets/js/map/hover_card.js`, `assets/js/map/truncate.js` (+ tests node:test)
  - Tests miroirs sous `test/`
- **Documentation de référence** : ADR 0005, ADR 0007, ADR 0006 (rendu des précisions), `.claude/rules/security.md` (validation des ids, échappement), `.claude/rules/liveview.md` (payloads client jamais fiables, pas de requête en mount), `.claude/rules/geo-temporal.md` (affichage selon précision), `.claude/memory/domain-model.md` (champs extract/wiki_url/fetched_at posés par #012).
- **Compétences requises** : LiveView (handle_event, push_event, composants fonction), MapLibre (événements de layer), JavaScript vanilla (DOM sûr, timers, cache), accessibilité de base (aria, alt).
- **Points d'attention** :
  - La décision endpoint léger vs propriétés embarquées est tranchée ci-dessus : ne pas embarquer les résumés dans `/api/events`, ne pas rouvrir la décision sans mesure contraire (la consigner en ADR si elle devait changer).
  - Jamais `innerHTML` avec du contenu distant, jamais `raw/1` en HEEx sur les extraits.
  - Le délai de 150 ms est un seul timer réarmé, pas un debounce de fetch séparé : le fetch part quand la bulle doit s'afficher et que le cache ne contient pas le QID.
  - L'attribution CC BY-SA avec lien vers l'article est une obligation de licence, pas un détail cosmétique : elle figure dans la bulle ET dans le panneau.
  - Aucun appel direct du client vers les serveurs Wikimedia : tout passe par le cache serveur constitué en #012.
  - Pas de tirets cadratins ni de mention d'outillage dans le code et les commits.
