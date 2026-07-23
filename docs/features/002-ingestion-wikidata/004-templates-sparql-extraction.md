# Issue #009 -- Templates SPARQL d'extraction, pagination, blocklist et decodeur

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #008

---

## Contexte

Cette issue livre la partie métier de l'extraction Wikidata : les requêtes SPARQL vétées qui sélectionnent le corpus (~420 000 événements datés et géolocalisables, étude `docs/studies/2026-07-sources-donnees-historiques.md`), la pagination stable qui permet de parcourir ce corpus par tranches rejouables, la liste noire des classes parasites, et le décodeur qui transforme les bindings SPARQL (#008) en structures de domaine normalisées (dates via #006).

Règle de sécurité : aucune interpolation brute dans les requêtes. Les templates sont des chaînes fixes du module, dont les seuls points variables (bornes de tranche, LIMIT, OFFSET, listes de QID) sont substitués après validation stricte (entiers, format `Q\d+`). Sobelow et la revue doivent pouvoir constater qu'aucune donnée externe ne peut altérer une requête.

Pièges Wikidata à traiter explicitement ici (`.claude/memory/data-sources.md`, skill `wikidata-query`) :

- Précision temporelle : lire `p:P585/psv:P585` puis `wikibase:timeValue` et `wikibase:timePrecision`. Le raccourci `wdt:P585` masque la précision et rend impossible la troncature des faux "1er janvier".
- Décalage RDF : le SPARQL livre les années négatives en convention astronomique XSD 1.1 (458 av. J.-C. = `-0457`). La normalisation est portée par `HistoricalDate.Wikidata.from_rdf/1` (#006) ; un test de régression sur la bataille de Marathon (Q31900) verrouille le comportement.
- Coordonnées : P625 direct d'abord, sinon héritées du lieu (P276 -> P625), avec provenance (`:direct` | `:place`) tracée jusqu'au stockage.
- Bruit de l'arbre `Q1190554` : saisons sportives, élections, épisodes, concerts, matchs ; exclusion par liste noire de classes maintenue en module.
- QLever : SPARQL 1.1 incomplet, utiliser `MINUS` plutôt que `FILTER NOT EXISTS`.

## User Story

> En tant que développeur du pipeline d'ingestion, je veux des requêtes SPARQL vétées, paginables et filtrées, et un décodeur testé sur des réponses réelles, afin d'extraire le corpus d'événements de manière sûre, stable et rejouable.

---

## Tâches

- [ ] Module `Amanogawa.Ingestion.Wikidata.Templates` : templates SPARQL en attributs de module, fonctions de rendu `events_page/1`, `count_events/0`... Chaque fonction de rendu valide ses paramètres (entiers non négatifs pour bornes/LIMIT/OFFSET, QID au format `~r/^Q\d+$/`) et lève `ArgumentError` sinon. Aucune concaténation de chaîne externe non validée.
- [ ] Template d'extraction des événements, aligné sur le pattern canonique du skill `wikidata-query` :
  - sélection `?e wdt:P31/wdt:P279* wd:Q1190554` ;
  - date : `p:P585/psv:P585` (valeur + `wikibase:timePrecision`), repli `p:P580/psv:P580` (début) ; fin optionnelle via `p:P582/psv:P582` ;
  - coordonnées : `OPTIONAL { ?e wdt:P625 ?coordDirect }` et `OPTIONAL { ?e wdt:P276/wdt:P625 ?coordPlace }`, variables distinctes pour tracer la provenance ; au moins une des deux exigée ;
  - labels et descriptions fr/en via `rdfs:label` / `schema:description` avec filtre de langue (ne pas dépendre de `SERVICE wikibase:label`, support incertain sur QLever) ;
  - sitelinks : URLs des articles fr et en (`schema:about` / `schema:isPartOf`) et `?e wikibase:sitelinks ?sitelinkCount` ;
  - classe P31 échantillonnée pour `kind` ;
  - agrégation `GROUP BY ?e` avec `SAMPLE` sur les variables optionnelles afin de garantir une ligne par événement (sinon les OPTIONAL multiplient les lignes) ;
  - exclusion de la blocklist par `MINUS { VALUES ?blocked { ... } ?e wdt:P31 ?blocked }`.
- [ ] Pagination stable par tranches de QID : l'espace des identifiants numériques (`xsd:integer` de la partie après "Q") est découpé en tranches `[lower, upper)` fournies par l'appelant ; à l'intérieur d'une tranche, `ORDER BY ?e` puis `LIMIT`/`OFFSET`. L'ordre total et le découpage indépendant des insertions ailleurs rendent le parcours rejouable et reprennable (le curseur de #010 est `{tranche, offset}`). Fournir aussi le template de comptage par tranche pour calibrer la taille des tranches.
- [ ] Module `Amanogawa.Ingestion.Wikidata.Blocklist` : liste de QID de classes exclues avec commentaire par entrée. Amorce : `Q27020041` (saison sportive), `Q40231` (élection), plus les classes d'épisodes, de concerts et de matchs sportifs dont les QID exacts seront confirmés par requêtes de comptage au moment de l'implémentation (tâche incluse : mesurer les 20 classes P31 les plus fréquentes du corpus et classer chacune garder/exclure). Fonction `qids/0` consommée par les templates ; la liste est un point de curation continue documenté dans le moduledoc.
- [ ] Structure `Amanogawa.Ingestion.Wikidata.ExtractedEvent` : `qid`, `label_fr`, `label_en`, `description_fr`, `description_en`, `kind` (QID de classe), `begin` et `end` (`%Amanogawa.HistoricalDate{}` ou nil), `geom` (`%Geo.Point{srid: 4326}`), `location_source` (`:direct` | `:place`), `wiki_url_fr`, `wiki_url_en`, `sitelink_count`.
- [ ] Module `Amanogawa.Ingestion.Wikidata.EventDecoder` : `decode/1` transformant un `%SparqlClient.Result{}` en liste d'`ExtractedEvent` :
  - extraction du QID depuis l'URI d'entité ;
  - dates via `HistoricalDate.Wikidata.from_rdf/1` (décalage RDF et troncature des faux 1er janvier traités là) ;
  - parsing WKT `Point(lon lat)` vers `%Geo.Point{}` SRID 4326 (attention à l'ordre longitude puis latitude du WKT) ;
  - priorité coordonnées directes, sinon lieu, `location_source` renseigné en conséquence ;
  - bindings invalides (date non parsable, WKT malformé, QID absent) : l'événement est écarté et compté, jamais de crash du lot ; retour `{events, rejected_count}`.
- [ ] Enregistrer les fixtures réelles QLever dans `test/support/fixtures/sparql/` : une page nominale d'événements variés (précisions 7, 9, 11 ; coordonnées directes et héritées ; sitelinks présents et absents), la bataille de Marathon (Q31900, réponse réelle, année RDF `-0489`), et des cas hostiles (précision manquante, WKT malformé, année très négative).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `events_page/1` rend un template contenant `psv:`, `wikibase:timePrecision`, le `MINUS` de blocklist, `GROUP BY`, et les bornes demandées ; `decode/1` sur la fixture nominale produit les `ExtractedEvent` attendus (dates, provenance des coordonnées, sitelink_count).
- [ ] **Edge case** : événement avec coordonnées héritées uniquement -> `location_source: :place` ; événement sans article fr ni en ; précision 7 (siècle) -> month/day nil ; événement avec date de début ET de fin.
- [ ] **Error case** : rendu de template avec paramètre non entier ou QID malformé -> `ArgumentError` ; `decode/1` sur binding à WKT malformé ou date non parsable écarte l'entrée et incrémente `rejected_count` sans lever.
- [ ] **Limit case** : tranche vide (0 binding) ; OFFSET 0 et LIMIT 1 ; année -123000 (préhistoire) décodée correctement.
- [ ] **Régression décalage RDF** : sur la fixture réelle de la bataille de Marathon (Q31900), le RDF livre l'année `-0489` ; le décodeur produit `begin.year == -489`, soit 490 av. J.-C. en convention astronomique (ADR 0006). Ce test documente explicitement pourquoi aucune correction d'année n'est appliquée au canal RDF (voir points d'attention).

### Property-based tests (si applicable)

- [ ] **Property (parseur)** : sur des résultats SPARQL synthétiques générés (années signées, précisions 0 à 11, WKT valides), `decode/1` ne lève jamais et tout événement décodé respecte les invariants : QID au bon format, `precision <= 9 => month/day nil`, `geom.srid == 4326`, `location_source` cohérente avec la variable de coordonnées présente.
- [ ] **Property (round-trip WKT)** : pour tout couple (lon, lat) généré dans les bornes valides, le parsing WKT redonne les coordonnées d'origine.

### Doctests (si applicable)

- [ ] **Doctest** : `Blocklist.qids/0` (liste non vide, format QID) ; exemple minimal de `EventDecoder` sur un binding inline dans le moduledoc.

### Tests d'intégration

- [ ] **Intégration** : chaîne complète sans réseau : `SparqlClientMock` renvoie la fixture réelle, `Templates.events_page/1` fournit la requête, `EventDecoder.decode/1` produit la liste finale ; vérifie le contrat exact attendu par le worker #010.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion/wikidata/templates.ex`
  - `lib/amanogawa/ingestion/wikidata/blocklist.ex`
  - `lib/amanogawa/ingestion/wikidata/extracted_event.ex`
  - `lib/amanogawa/ingestion/wikidata/event_decoder.ex`
  - `test/amanogawa/ingestion/wikidata/templates_test.exs`
  - `test/amanogawa/ingestion/wikidata/blocklist_test.exs`
  - `test/amanogawa/ingestion/wikidata/event_decoder_test.exs`
  - `test/support/fixtures/sparql/events_page.json`, `test/support/fixtures/sparql/marathon_q46335.json`, fixtures hostiles associées
- **Documentation de référence** : `.claude/skills/wikidata-query/SKILL.md` (pattern canonique et pièges), `.claude/memory/data-sources.md`, étude §1 et §5, ADR 0003 et 0006, [Help:Dates](https://www.wikidata.org/wiki/Help:Dates).
- **Compétences requises** : SPARQL (property paths, psv:, GROUP BY/SAMPLE, MINUS, VALUES), spécificités QLever, bibliothèque geo (WKT), StreamData.
- **Points d'attention** :
  - Décalage RDF, sens exact : le RDF est déjà en convention astronomique (la nôtre, ADR 0006), c'est le canal JSON des dumps qui est décalé. Pour Marathon, RDF `-0489` = interne -489 = 490 av. J.-C. La mention "-490" de la vue d'ensemble F02 correspond à la valeur JSON, pas à la valeur interne : ne pas "corriger" l'année RDF.
  - `wdt:P625` sur le lieu (P276) peut retourner plusieurs lieux ou aucun ; le `SAMPLE` du GROUP BY tranche, la précision géographique fine n'est pas un objectif ici.
  - La blocklist s'applique sur P31 direct (via `VALUES`), pas sur la fermeture P279* (coût) ; si le bruit résiduel est trop fort, l'élargissement est une évolution mesurée, pas un défaut de cette issue.
  - Calibrer la taille des tranches de QID avec le template de comptage : viser des pages de quelques milliers de bindings maximum.
  - Ne jamais exécuter de requête réelle depuis les tests ; la capture des fixtures se fait hors suite de tests et se documente dans `test/support/fixtures/sparql/README.md` (#008).
