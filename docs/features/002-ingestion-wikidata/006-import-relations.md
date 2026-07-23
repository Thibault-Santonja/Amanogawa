# Issue #011 -- Import des relations entre événements

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #010

---

## Contexte

Les liens typés entre événements sont une richesse majeure du corpus : hiérarchie guerre/campagne/bataille (`P361`, ~740 000 déclarations sur l'arbre événement), chaînage chronologique (`P155`/`P156`, ~495 000), événements significatifs (`P793`) et participations (`P1344`). L'étude écarte `P828`/`P1542` (cause/effet, ~7 400 seulement) comme relations structurantes ; les types `:cause`/`:effect` du schéma `EventLink` restent disponibles pour un enrichissement ultérieur.

Cette issue étend le pipeline de #010 : un template SPARQL de relations, un décodeur, et un worker Oban qui importe les liens via `Amanogawa.Atlas.upsert_event_links/1` (#007). Règle centrale : un `EventLink` n'est créé que si les deux événements existent localement (la façade Atlas ignore et compte les paires dont un QID est inconnu ; c'est attendu, le corpus local est un sous-ensemble filtré de Wikidata).

Mapping des propriétés vers les types de lien :

| Propriété Wikidata | Sens | EventLink |
|---|---|---|
| `A P361 B` (partie de) | A est une partie de B | `(source: A, target: B, :part_of)` |
| `A P155 B` (précédé de) | A suit B | `(source: A, target: B, :follows)` |
| `A P156 B` (suivi de) | B suit A | `(source: B, target: A, :follows)` |
| `A P793 B` (événement significatif) | B est significatif pour A | `(source: A, target: B, :significant)` |
| `A P1344 B` (participant de) | A participe à B | `(source: A, target: B, :part_of)` |

`P155`/`P156` sont normalisées en une seule direction `:follows` ("source suit target") : les paires symétriques déclarées des deux côtés produisent le même lien, dédoublonné avant insertion. `P1344` entre deux événements est traitée comme une inclusion (l'événement participant s'inscrit dans l'événement englobant) ; ce choix est documenté dans le moduledoc du décodeur.

## User Story

> En tant qu'utilisateur de la carte et de la frise, je veux que les événements soient reliés (bataille -> guerre, événement -> événement suivant) afin de naviguer dans le contexte historique d'un événement au lieu de le voir isolé.

---

## Tâches

- [ ] Étendre `Amanogawa.Ingestion.Wikidata.Templates` : template `links_page/1` sélectionnant, pour chaque propriété (`P361`, `P155`, `P156`, `P793`, `P1344`), les paires `?source ?target ?property` où source et cible appartiennent à l'arbre `Q1190554` (mêmes garde-fous que #009 : rendu vété, tranches de QID sur la source, `ORDER BY`, `LIMIT`/`OFFSET`, une variable identifiant la propriété d'origine). Pas de blocklist ici : le filtrage effectif est fait par l'existence locale des deux QID.
- [ ] Structure `Amanogawa.Ingestion.Wikidata.ExtractedLink` : `source_qid`, `target_qid`, `type` (`:part_of` | `:follows` | `:significant`), `property` (P-id d'origine, pour les métriques).
- [ ] Module `Amanogawa.Ingestion.Wikidata.LinkDecoder` : `decode/1` transformant un `%SparqlClient.Result{}` en liste d'`ExtractedLink` : extraction des QID, application du mapping ci-dessus (dont l'inversion de direction pour `P156`), rejet compté des bindings invalides, dédoublonnage des liens identiques après normalisation, exclusion des auto-liens (`source == target`, ça existe dans Wikidata).
- [ ] Worker `Amanogawa.Ingestion.Workers.ImportLinks` (queue `:ingestion`) : même orchestration que #010 (pagination par tranches, un job par page, curseur, enchaînement, clôture), `SyncRun` de kind `links`, écriture via `Amanogawa.Atlas.upsert_event_links/1` uniquement.
- [ ] Métriques du run dans `counts` : `pages`, `links_fetched`, `links_created`, `links_skipped_missing` (paires dont un événement est absent localement), `links_rejected` (bindings invalides), et ventilation par propriété d'origine (`by_property: %{"P361" => n, ...}`).
- [ ] Façade `Amanogawa.Ingestion` : `start_links_import/1` et `resume_links_import/1` (mêmes contrats que #010, refus de runs `links` concurrents).
- [ ] Fixtures réelles dans `test/support/fixtures/sparql/` : une page de relations mêlant les cinq propriétés, avec des paires dont les deux membres seront présents localement et d'autres non, un auto-lien, et un doublon symétrique `P155`/`P156`.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `decode/1` mappe chaque propriété vers le bon type et la bonne direction (cas nominal des cinq propriétés).
- [ ] **Edge case** : paire déclarée des deux côtés (`A P156 B` et `B P155 A`) produit un seul lien après dédoublonnage ; auto-lien écarté et compté.
- [ ] **Error case** : binding sans QID cible ou avec URI non entité écarté sans lever ; rendu de template avec paramètres invalides -> `ArgumentError`.
- [ ] **Limit case** : page vide ; page ne contenant que des liens vers des événements absents localement (0 création, tout en `skipped_missing`).

### Property-based tests (si applicable)

- [ ] **Property** : sur des ensembles de paires générés (avec symétries `P155`/`P156` et doublons injectés), le décodage normalisé ne produit jamais deux liens identiques `(source, target, type)` ni d'auto-lien.

### Doctests (si applicable)

- [ ] **Doctest** : table de mapping illustrée dans le moduledoc de `LinkDecoder` (un exemple `P156` montrant l'inversion de direction).

### Tests d'intégration

- [ ] **Intégration (DataCase + Oban.Testing, Mox)** : base préchargée avec un sous-ensemble d'événements (builder de #007), import des relations depuis les fixtures -> seuls les liens dont les deux événements existent sont créés, compteurs exacts (`created`, `skipped_missing`, ventilation par propriété), `SyncRun` `completed`.
- [ ] **Intégration (idempotence)** : rejouer l'import des liens ne crée aucun doublon (contrainte unique + `on_conflict: :nothing`) et aboutit au même état.
- [ ] **Intégration (reprise)** : échec durable sur une page -> run `failed` avec curseur ; reprise -> état final identique à un import sans incident.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion/wikidata/templates.ex` (ajout `links_page/1` et comptage)
  - `lib/amanogawa/ingestion/wikidata/extracted_link.ex`
  - `lib/amanogawa/ingestion/wikidata/link_decoder.ex`
  - `lib/amanogawa/ingestion/workers/import_links.ex`
  - `lib/amanogawa/ingestion.ex` (fonctions de façade)
  - `test/amanogawa/ingestion/wikidata/link_decoder_test.exs`
  - `test/amanogawa/ingestion/workers/import_links_test.exs`
  - `test/support/fixtures/sparql/links_page.json`
- **Documentation de référence** : étude §4 (densités mesurées, choix des propriétés), ADR 0003, `.claude/memory/domain-model.md` (types d'`EventLink`), #007 (contrat `upsert_event_links/1`), #010 (orchestration et `SyncRun`).
- **Compétences requises** : SPARQL (UNION ou VALUES sur les propriétés), Oban, modélisation de graphes dirigés.
- **Points d'attention** :
  - L'import des liens doit tourner APRÈS l'import des événements (prérequis #010, ordre orchestré en #013) : lancé sur une base vide, il ne crée rien, tout part en `skipped_missing`. Comportement correct mais inutile.
  - `skipped_missing` élevé est normal (le corpus local est filtré) : c'est une métrique de couverture, pas une erreur. La documenter comme telle dans le moduledoc.
  - La direction des liens est un contrat d'affichage : "source suit target", "source est partie de target". La fixer une fois ici et ne plus jamais l'inverser en aval.
  - Restreindre source ET cible à l'arbre `Q1190554` dans le template limite le volume transféré ; le filtre définitif reste l'existence locale.
  - `:cause`/`:effect` (P828/P1542) : hors périmètre, ne pas les importer ici ; le schéma les accepte déjà si un besoin futur est validé.
