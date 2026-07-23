# Issue #006 -- Modèle temporel HistoricalDate

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #001

---

## Contexte

Le projet couvre de la préhistoire (centaines de milliers d'années avant notre ère) à aujourd'hui. Le type `date` de PostgreSQL ne descend pas sous l'an -4713 et les types date des langages supposent des calendriers modernes : l'ADR 0006 décide donc de représenter toute date historique par un embedded schema `HistoricalDate` portant l'année en entier signé (convention astronomique : 1 av. J.-C. = année 0), un mois et un jour nullables, une précision explicite (échelle Wikidata 0 à 11) et un calendrier d'affichage.

Ce module est le socle de tout l'axe temporel du projet : colonnes plates `begin_*`/`end_*` du schéma Event (#007), normalisation des dates dans le décodeur SPARQL (#009), tri chronologique, filtres de la frise, affichage honnête ("VIIIe siècle av. J.-C.", jamais "1er janvier -0750" pour une date connue au siècle près).

Placement : `HistoricalDate` est un value object partagé par les contextes Atlas (stockage), Ingestion (normalisation) et par la couche web (affichage). Pour respecter la règle "aucun appel de module interne entre contextes", il vit au-dessus des bounded contexts, en module `Amanogawa.HistoricalDate` (shared kernel), et ne dépend d'aucun contexte.

Les pièges Wikidata documentés dans `.claude/memory/data-sources.md` sont traités ici sous forme de fonctions pures de normalisation, que l'adaptateur d'ingestion appellera en #009 :

- Le RDF/SPARQL suit XSD 1.1, déjà en convention astronomique : 458 av. J.-C. apparaît en `-0457`. L'année RDF est donc reprise telle quelle, sans correction. Le format JSON des dumps, lui, note 1 av. J.-C. en `-0001` : il faut décaler les années négatives de +1. La normalisation dépend donc du canal, et un test de régression sur un événement BCE connu empêche toute "correction" erronée future.
- Épidémie de faux "1er janvier" : la valeur stockée par Wikidata contient toujours un mois et un jour factices. Si la précision est <= 9 (année ou plus grossier), mois et jour sont tronqués ; si la précision est 10 (mois), le jour est tronqué.
- Les valeurs Wikidata sont stockées en grégorien proleptique ; le calendrier julien (Q1985786) est une information d'affichage uniquement.

## User Story

> En tant que développeur du pipeline d'ingestion, je veux un modèle de date historique unique et normalisé (année astronomique signée, précision explicite) afin de stocker, trier, comparer et afficher des dates de la préhistoire à aujourd'hui sans jamais inventer un mois ou un jour que la source ne connaît pas.

---

## Tâches

- [ ] Créer l'embedded schema `Amanogawa.HistoricalDate` : `year` (:integer, obligatoire, convention astronomique), `month` et `day` (:integer, nullables), `precision` (:integer, obligatoire, 0 à 11), `calendar` (Ecto.Enum `:gregorian` | `:julian`, défaut `:gregorian`).
- [ ] Écrire `changeset/2` avec les invariants : `precision` dans 0..11 ; si `precision <= 9`, `month` et `day` forcés à nil ; si `precision == 10`, `day` forcé à nil ; `month` dans 1..12 et `day` dans 1..31 quand présents ; `month` obligatoire si `day` présent.
- [ ] Écrire `new/1` (constructeur validant, retourne `{:ok, %HistoricalDate{}}` ou `{:error, changeset}`) et `new!/1`.
- [ ] Écrire `sort_key/1` et `compare/2` implémentant l'ordre chronologique `(year, month NULLS FIRST, day NULLS FIRST)` ; documenter que la comparaison intra-année n'est significative que si les deux dates ont `precision >= 10` (sinon égalité au niveau de l'année).
- [ ] Créer `Amanogawa.HistoricalDate.Wikidata` (normalisation pure, sans transport) :
  - `from_rdf/1` : entrée `%{time: "-0489-09-12T00:00:00Z", precision: 11, calendar: "http://www.wikidata.org/entity/Q1985786"}` telle qu'issue des résultats SPARQL. Année reprise telle quelle (le RDF est déjà astronomique), mois/jour tronqués selon la précision, calendrier mappé (Q1985727 -> `:gregorian`, Q1985786 -> `:julian`).
  - `from_json/1` : même logique pour le format des dumps JSON, avec décalage de +1 sur les années <= -1 (le JSON note 1 av. J.-C. = `-0001`, en interne 1 av. J.-C. = 0).
  - Parsing robuste des chaînes temporelles à années longues ou négatives (`-123000-01-01T00:00:00Z`) : ne jamais passer par `Date`/`DateTime` Elixir, parser année/mois/jour par expression régulière ou découpage manuel.
- [ ] Créer `Amanogawa.HistoricalDate.Formatter` : `format/2` (date, locale `:fr` par défaut, `:en` supporté) respectant strictement la précision :
  - 11 : "12 septembre 490 av. J.-C." / "1789" avec jour et mois ;
  - 10 : "septembre 1789" ;
  - 9 : "1789", "490 av. J.-C." ;
  - 8 : "années 1780", "années 490 av. J.-C." ;
  - 7 : "XVIIIe siècle", "VIIIe siècle av. J.-C." (chiffres romains) ;
  - 6 : "IIe millénaire av. J.-C." ;
  - 0 à 5 : ordres de grandeur ("il y a environ 100 000 ans", "il y a environ 2 millions d'années").
  - Conversion affichage : année astronomique `y <= 0` rendue comme `1 - y` av. J.-C. (année 0 = "1 av. J.-C.", année -489 = "490 av. J.-C.").
- [ ] Doctests dans les moduledocs de `Formatter` et de `Wikidata` (exemples significatifs, dont un cas BCE).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : changeset valide pour une date complète (year 1789, month 7, day 14, precision 11) et pour une année seule (year -489, precision 9, month/day nil).
- [ ] **Edge case** : année 0 (= 1 av. J.-C.) acceptée et formatée "1 av. J.-C." ; année très négative (-123000, precision 6) acceptée ; `compare/2` entre une date precision 9 et une date precision 11 de la même année retourne l'égalité au niveau année.
- [ ] **Error case** : precision hors 0..11 rejetée ; day sans month rejeté ; month 13 ou day 32 rejetés ; month/day fournis avec precision <= 9 sont tronqués (pas d'erreur, normalisation) ; chaîne temporelle non parsable retourne une erreur taguée.
- [ ] **Limit case** : precision 0 et precision 11 (bornes) ; month 12 et day 31 ; `from_json` sur `-0001-...` donne year 0 ; `from_rdf` sur `0000-...` donne year 0.

### Property-based tests (si applicable)

- [ ] **Property (round-trip inter-canaux)** : pour toute date historique générée, ses représentations RDF et JSON équivalentes normalisées par `from_rdf/1` et `from_json/1` produisent le même `%HistoricalDate{}`.
- [ ] **Property (invariant de précision)** : toute sortie de la normalisation vérifie `precision <= 9 => month == nil and day == nil` et `precision == 10 => day == nil`.
- [ ] **Property (tri)** : trier une liste générée par `sort_key/1` produit l'ordre `(year, month NULLS FIRST, day NULLS FIRST)` ; `compare/2` est antisymétrique et transitive sur des triplets générés.
- [ ] **Property (formatter)** : pour toute date de precision <= 9, la sortie de `format/2` ne contient ni nom de mois ni numéro de jour ; `format/2` ne lève jamais d'exception sur une date valide.

### Doctests (si applicable)

- [ ] **Doctest** : `Formatter.format/2` sur un siècle BCE, sur une année simple, sur une date au jour près.
- [ ] **Doctest** : `Wikidata.from_rdf/1` sur la date de la bataille de Marathon (voir points d'attention) et `Wikidata.from_json/1` sur la même date côté JSON, montrant la convergence des deux canaux.

### Tests d'intégration

- [ ] **Intégration** : aucun. Module pur sans dépendance externe ni base de données ; l'intégration en base (colonnes plates) est couverte par #007.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/historical_date.ex`
  - `lib/amanogawa/historical_date/wikidata.ex`
  - `lib/amanogawa/historical_date/formatter.ex`
  - `test/amanogawa/historical_date_test.exs`
  - `test/amanogawa/historical_date/wikidata_test.exs`
  - `test/amanogawa/historical_date/formatter_test.exs`
- **Documentation de référence** : ADR 0006 (modèle temporel), `.claude/rules/geo-temporal.md`, `.claude/memory/data-sources.md` (pièges des dates), étude `docs/studies/2026-07-sources-donnees-historiques.md` §5, [Help:Dates](https://www.wikidata.org/wiki/Help:Dates).
- **Compétences requises** : Ecto `embedded_schema` et changesets, StreamData (générateurs composés, propriétés d'ordre), conventions de numérotation des années (astronomique vs historique).
- **Points d'attention** :
  - Convention astronomique stricte (ADR 0006) : 490 av. J.-C. = année -489. Le RDF SPARQL livre déjà cette valeur (`-0489`) ; c'est le canal JSON qui livre `-0490` et demande un décalage. La vue d'ensemble F02 documente la même convention (valeur interne -489 pour Marathon, Q46335).
  - Ne jamais utiliser `Date`/`NaiveDateTime` Elixir pour parser ou stocker ces valeurs : plages insuffisantes pour la préhistoire.
  - Le calendrier est une métadonnée d'affichage : aucune conversion julien/grégorien des valeurs, qui restent en grégorien proleptique.
  - La lecture de la précision via `psv:`/`wikibase:timePrecision` relève du template SPARQL (#009) ; ici on suppose la précision déjà extraite en entier.
  - Formatter : prévoir la locale en paramètre (fr défaut, en supporté) ; l'internationalisation Gettext complète viendra avec la couche web.
