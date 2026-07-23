# Issue #029 -- Tests E2E du parcours critique (outillage navigateur)

**Feature :** F03 -- Carte interactive
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #016, #017, #018

---

## Contexte

Les issues #015 à #018 spécifiaient chacune des tests E2E. À la livraison de F03, aucun outillage navigateur n'existe dans le dépôt (ni Wallaby ni équivalent), et les vérifications de bout en bout ont été faites manuellement (curl, inspection du HTML rendu, données de développement). La revue qualité de F03 a exigé que ce report soit acté formellement plutôt que passé sous silence : c'est l'objet de cette issue.

Le risque couvert par les E2E est précisément celui que les tests unitaires et LiveViewTest ne voient pas : les contrats hook <-> LiveView exécutés dans un vrai navigateur (garde anti-boucle de `map_moved`, re-pose des sources après `setStyle`, rendu WebGL des marqueurs, hover réel, navigation avec URL partageable).

## User Story

> En tant que mainteneur, je veux un parcours critique automatisé dans un vrai navigateur afin de détecter les régressions d'intégration carte/LiveView que les tests unitaires ne peuvent pas voir.

---

## Tâches

- [ ] Choisir et installer l'outillage : Wallaby avec chromedriver (candidat par défaut), en pesant PhoenixTest si le rendu canvas rend Wallaby peu assertif ; documenter le choix dans l'issue au moment de l'implémentation.
- [ ] Intégrer l'outillage en CI (installation du navigateur headless dans le workflow, temps de build maîtrisé).
- [ ] Implémenter le parcours critique de #018 : charger `/`, attendre la carte, sélectionner un événement (via l'API du hook ou un clic simulé), vérifier `sel` dans l'URL, vérifier le panneau (titre, attribution, bouton Wikipedia avec `rel="noopener noreferrer"`), recharger l'URL partagée et vérifier la restauration de l'état, fermer par Échap.
- [ ] Couvrir le hover (bulle après le micro-délai, disparition au départ du curseur).
- [ ] Couvrir l'affichage des lignes de relations à la sélection et leur nettoyage à la désélection.
- [ ] Étiqueter la suite (`@moduletag :e2e`) pour pouvoir l'exclure des runs rapides locaux tout en la gardant obligatoire en CI.

---

## Tests à écrire

### Tests end-to-end

- [ ] **E2E** : parcours critique complet décrit ci-dessus (le livrable principal de cette issue).
- [ ] **E2E** : navigation entre deux sélections successives sans désélection intermédiaire (lignes de relations remplacées, pas cumulées).
- [ ] **E2E** : dark mode (émulation `prefers-color-scheme`) : la carte bascule de style et les événements restent affichés.

### Autres catégories

- Tests unitaires, property-based, doctests, intégration : non applicables, couverts par les issues #014 à #018.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** : `mix.exs` (dépendance test), `test/e2e/`, `.github/workflows/ci.yml`, `config/test.exs`.
- **Documentation de référence** : issues #015 à #018 (sections E2E), `assets/js/hooks/map_hook.js` (contrats d'événements nommés).
- **Points d'attention** : le rendu MapLibre est un canvas WebGL : les assertions passent par l'URL, le DOM du panneau et de la hover card, et l'état du hook exposé pour les tests, pas par le contenu du canvas. Prévoir un fixture set d'événements stable inséré par la suite E2E elle-même.
