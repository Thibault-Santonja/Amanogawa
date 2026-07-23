# Issue #019 -- TimeScale symlog partagé Elixir + JS

**Feature :** F04 -- Frise chronologique
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #006

---

## Contexte

La frise chronologique couvre de la préhistoire (plusieurs centaines de milliers d'années) à aujourd'hui. Une échelle linéaire écraserait toute l'histoire écrite dans quelques pixels ; une échelle purement logarithmique rendrait le passé récent illisible. L'ADR 0005 et la règle géo-temporelle imposent une échelle symlog : linéaire près du présent, logarithmique vers le passé, avec un pivot paramétré autour de -10 000 (début du Néolithique, zone de transition entre les deux régimes).

Cette échelle est utilisée des deux côtés de la pile :

- côté Elixir, pour l'agrégation SQL de l'histogramme de densité (#020), la validation des fenêtres temporelles et tout calcul serveur dépendant de la position d'une année ;
- côté JS, dans le `TimelineHook` (#020, #021) pour placer l'axe, les graduations, l'histogramme et la fenêtre.

Si les deux implémentations divergent, la frise et l'histogramme se désynchronisent (une barre de densité décalée par rapport à la graduation, une fenêtre qui ne couvre pas les événements affichés). La cohérence Elixir/JS est donc le coeur de cette issue : mêmes formules, mêmes constantes, mêmes fixtures d'ancres testées des deux côtés.

Le module s'insère dans le contexte Atlas (`Amanogawa.Atlas.TimeScale`) car il fait partie du modèle temporel servi à l'UI, au même titre que `HistoricalDate` (#006, ADR 0006). Les années manipulées sont des entiers signés en convention astronomique (1 BCE = année 0).

## User Story

> En tant que développeur de la frise et de la carte, je veux une échelle temporelle symlog implémentée à l'identique en Elixir et en JS afin que toute année soit placée exactement à la même position normalisée côté serveur (histogramme SQL, validations) et côté client (axe, fenêtre, graduations).

---

## Tâches

- [ ] Créer `Amanogawa.Atlas.TimeScale` : struct de configuration `%TimeScale{min_year, max_year, pivot}` avec valeurs par défaut documentées (proposition : `min_year: -300_000`, `max_year: 2_100`, `pivot: 10_000`) et constructeur `new/1` validant `min_year < max_year` et `pivot > 0`.
- [ ] Documenter la formule dans le `@moduledoc` (elle fait foi pour les deux implémentations) :
  - `t(année) = ln(1 + (max_year - année) / pivot)`
  - `position(année) = 1 - t(année) / t(min_year)` (position dans [0,1], 0 = passé lointain, 1 = présent)
  - `année(position) = max_year - pivot * (exp((1 - position) * t(min_year)) - 1)`
- [ ] Implémenter `position/2` (année -> position [0,1]) et `year/2` (position -> année, arrondi documenté) ; comportement aux bornes explicite : les valeurs hors domaine sont clampées, jamais d'exception (choix documenté dans le moduledoc).
- [ ] Implémenter `ticks/3` (graduations adaptatives) : pour une sous-fenêtre `[from, to]` et un nombre cible de graduations, retourner une liste croissante d'années "rondes" (pas choisi parmi 1, 2, 5 x 10^n, adapté localement puisque le pas en années varie le long de l'axe symlog). Dans la zone profonde (années <= -10 000), générer les graduations sur des valeurs rondes en "années BP" (BP = avant 1950, convention radiocarbone) pour préparer les libellés "100 ka BP" de l'issue #020 ; documenter cette convention dans le moduledoc.
- [ ] Créer l'util JS miroir `assets/js/lib/time_scale.js` : module ES vanilla exportant `createTimeScale(config)` avec `position(year)`, `year(position)`, `ticks(from, to, count)`, exactement les mêmes formules, les mêmes valeurs par défaut et le même clamp. Aucune dépendance (pas de d3 ici : d3 n'intervient qu'au rendu, #020).
- [ ] Créer la fixture canonique partagée `test/support/fixtures/time_scale/anchors.json` : liste d'ancres `{year, position}` calculées avec la configuration par défaut, au minimum les années -100 000, -10 000, -490 (bataille de Marathon, ancre BCE déjà utilisée en F02), 0, 1000, 1789, 2000, plus les bornes du domaine (positions 0 et 1). Les positions attendues sont écrites en dur dans le fichier (pas générées à la volée) ; tolérance de comparaison 1.0e-9 documentée dans le fichier même (clé `tolerance`).
- [ ] Écrire les tests ExUnit lisant cette fixture et vérifiant chaque ancre.
- [ ] Écrire les tests JS avec `node:test` (décision prise dans cette issue, voir Points d'attention) : `assets/js/test/time_scale.test.js` lit la MÊME fixture (chemin relatif vers `test/support/fixtures/time_scale/anchors.json`) et vérifie les mêmes ancres avec la même tolérance.
- [ ] Ajouter le script npm `"test": "node --test test/"` dans `assets/package.json`, une étape `npm test --prefix assets` dans le workflow CI (`.github/workflows/ci.yml`) et l'intégrer à l'alias `mix precommit`.
- [ ] Écrire les property tests StreamData côté Elixir (voir plan de tests).
- [ ] Mettre à jour `.claude/memory/domain-model.md` (section frise) avec la configuration par défaut retenue et l'emplacement de la fixture partagée.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `position/2` et `year/2` retournent les valeurs attendues pour chaque ancre de `anchors.json` (tolérance 1.0e-9) ; idem côté JS avec `node:test` sur la même fixture.
- [ ] **Happy path** : `ticks/3` sur la fenêtre [1700, 2000] retourne des années rondes (multiples de 50 ou 100 selon le nombre cible), strictement croissantes et incluses dans la fenêtre.
- [ ] **Edge case** : `ticks/3` sur une fenêtre traversant le pivot (ex. [-15 000, -5 000]) retourne des graduations cohérentes de part et d'autre (valeurs BP rondes côté profond, années rondes côté récent).
- [ ] **Edge case** : fenêtre très étroite (ex. [1969, 1970]) : `ticks/3` ne retourne pas de doublon et gère un pas de 1 an.
- [ ] **Error case** : `new/1` rejette `min_year >= max_year` et `pivot <= 0` avec une erreur explicite ; mêmes rejets côté JS (`createTimeScale` lève une exception documentée).
- [ ] **Limit case** : `position(min_year) == 0.0`, `position(max_year) == 1.0`, valeurs hors domaine clampées (`position(-1_000_000) == 0.0`) ; mêmes assertions côté JS.

### Property-based tests

- [ ] **Property (monotonie)** : pour tout couple d'années `a < b` dans le domaine, `position(a) < position(b)` (StreamData, générateur d'entiers dans le domaine).
- [ ] **Property (round-trip)** : pour toute année du domaine, `year(position(année))` retourne l'année à l'arrondi près (écart absolu <= 1 an, l'exponentielle amplifiant les erreurs flottantes dans le passé profond : tolérance documentée).
- [ ] **Property (bornes)** : pour toute année du domaine, `position(année)` est dans [0.0, 1.0].
- [ ] **Property (ticks)** : pour toute fenêtre valide, `ticks/3` retourne une liste strictement croissante, sans doublon, contenue dans la fenêtre.

### Doctests

- [ ] **Doctest** : `position/2` et `year/2` avec la configuration par défaut sur une ancre lisible (ex. année 2000), et `new/1` montrant la configuration.

### Tests d'intégration

- [ ] **Intégration** : test de cohérence croisée : les suites ExUnit et node:test consomment strictement le même fichier `anchors.json` (aucune copie) ; un test ExUnit vérifie en plus que le fichier est un JSON valide contenant toutes les ancres obligatoires listées ci-dessus (garde-fou contre une fixture appauvrie).

### Tests end-to-end

- [ ] **E2E** : non applicable ici : aucun rendu ni interaction navigateur dans cette issue (couvert par #020 et #021).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/atlas/time_scale.ex` (nouveau)
  - `test/amanogawa/atlas/time_scale_test.exs` (nouveau)
  - `assets/js/lib/time_scale.js` (nouveau)
  - `assets/js/test/time_scale.test.js` (nouveau)
  - `test/support/fixtures/time_scale/anchors.json` (nouveau, fixture canonique partagée)
  - `assets/package.json` (script `test`)
  - `.github/workflows/ci.yml` (étape `npm test --prefix assets`)
  - `mix.exs` (alias `precommit`)
  - `.claude/memory/domain-model.md` (configuration retenue)
- **Documentation de référence** : ADR 0006 (modèle temporel, convention astronomique), ADR 0005 (d3 limité au rendu), `.claude/rules/geo-temporal.md` (échelle symlog, module partagé testé sur ancres connues), `.claude/rules/testing.md` (property tests obligatoires pour l'échelle symlog), issue #006 (HistoricalDate).
- **Compétences requises** : mathématiques de l'échelle symlog (log1p/expm1 pour la stabilité numérique), StreamData, modules ES vanilla et `node:test`, partage de fixtures JSON entre deux suites de tests.
- **Points d'attention** :
  - Choix du framework de test JS tranché ici : `node:test` (natif Node >= 20) plutôt que vitest, conformément à la règle "minimiser les dépendances externes" (CLAUDE.md) ; aucune dépendance npm de test à installer, exécution par `node --test`. Revenir sur ce choix si un besoin de DOM testing apparaît plus tard (nouvelle décision documentée).
  - Utiliser `:math.log/1` et `:math.exp/1` côté Elixir, `Math.log1p`/`Math.expm1` côté JS quand la stabilité numérique l'exige ; vérifier que les deux implémentations restent dans la tolérance de la fixture (c'est précisément ce que les ancres garantissent).
  - Les positions de la fixture sont figées en dur : si la configuration par défaut change, la fixture doit être régénérée et les DEUX suites de tests doivent échouer puis repasser ensemble.
  - Convention astronomique partout : -490 est l'année astronomique de la bataille de Marathon (voir les pièges de décalage d'un an documentés en F02 et `.claude/memory/data-sources.md`) ; ne pas mélanger les conventions dans les libellés de la fixture.
  - Pas de d3 dans `time_scale.js` : le module doit rester pur et testable sous Node sans DOM.
  - `mix precommit` doit passer, y compris les nouveaux tests JS intégrés à l'alias.
