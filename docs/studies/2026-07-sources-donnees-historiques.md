# Étude : sources de données pour la visualisation d'événements historiques

Date : 2026-07-23
Statut : Terminée (fonde les ADR 0003 et 0004)

## 1. Wikidata comme source d'événements

### Modèle de données pertinent

- Classe racine : `Q1190554` (occurrence / événement), sous-classes utiles : `Q178561` (bataille), `Q198` (guerre), `Q131569` (traité), `Q3839081` (catastrophe), `Q124734` (révolte). Filtre : `?e wdt:P31/wdt:P279* wd:Q1190554`.
- Propriétés clés : `P585` (date), `P580`/`P582` (début/fin), `P625` (coordonnées), `P276` (lieu), `P17` (pays), sitelinks `schema:about`/`schema:isPartOf` pour les articles Wikipedia.
- Exemples : [SPARQL query service/queries/examples](https://www.wikidata.org/wiki/Wikidata:SPARQL_query_service/queries/examples).

### Volumétrie mesurée (23/07/2026, endpoint QLever, données vivantes)

| Mesure | Nombre |
|---|---|
| Événements (arbre Q1190554) | 4 769 919 |
| ... avec coordonnées P625 | 233 758 |
| ... avec P625 ET date (P585 ou P580) | 67 664 |
| ... P625 + date + article Wikipedia EN | 29 361 |
| ... P625 + date + article Wikipedia FR | 17 258 |
| Événements avec date + coordonnées via le lieu (P276 -> P625) | 419 936 |
| Batailles (Q178561) : total / avec coordonnées | 19 947 / 9 476 |

Enseignement majeur : les coordonnées directes sont rares ; la résolution indirecte via le lieu multiplie par 6 le corpus géolocalisable (~420 000 événements). L'arbre Q1190554 est bruité (saisons sportives, élections, concerts) : prévoir une liste noire de classes P31.

### Limites du WDQS et alternatives

- **WDQS** (`https://query.wikidata.org/sparql`) : timeout 60 s, 5 requêtes parallèles/IP, 30 erreurs/min puis HTTP 429 et bannissement temporaire. [User Manual](https://www.mediawiki.org/wiki/Wikidata_Query_Service/User_Manual). Les requêtes `P31/P279*` globales y timeoutent presque systématiquement.
- **Graph split (mai 2025)** : main graph seul sur query.wikidata.org, articles savants sur query-scholarly. Sans impact ici. [WDQS graph split](https://www.wikidata.org/wiki/Wikidata:SPARQL_query_service/WDQS_graph_split).
- **QLever** (`https://qlever.dev/api/wikidata`, université de Fribourg) : ordres de grandeur plus rapide (toutes les requêtes de comptage ci-dessus passent en secondes). SPARQL 1.1 incomplet (utiliser `MINUS` plutôt que `FILTER NOT EXISTS`), rechargé depuis les dumps (pas temps réel). [Alternative endpoints](https://www.wikidata.org/wiki/Wikidata:SPARQL_query_service/Alternative_endpoints).
- **Dumps** : `https://dumps.wikimedia.org/wikidatawiki/entities/` (JSON hebdomadaire, 100+ Go compressés) pour une ingestion batch reproductible à terme.
- **Linked Data Fragments** : lent, calcul client ; non prioritaire.

## 2. API Wikipedia (résumés)

- Endpoint actif en 2026 : `https://{lang}.wikipedia.org/api/rest_v1/page/summary/{titre}` : `title`, `description`, `extract`, `extract_html`, `thumbnail`, `originalimage`, `content_urls`, `wikibase_item`. Fonctionne en fr et en. L'URL est conservée malgré la migration RESTBase -> Page Content Service ([T262315](https://phabricator.wikimedia.org/T262315)).
- Règles d'usage : User-Agent descriptif avec contact obligatoire, durcissement 2026 des limites pour le trafic anonyme automatisé. [Rate limits](https://www.mediawiki.org/wiki/Wikimedia_APIs/Rate_limits), [API:Etiquette](https://www.mediawiki.org/wiki/API:Etiquette), [Usage Guidelines](https://foundation.wikimedia.org/wiki/Policy:Wikimedia_Foundation_API_Usage_Guidelines).
- Licences : Wikidata CC0 ; textes Wikipedia (extraits inclus) CC BY-SA 4.0, attribution + lien obligatoires.

## 3. Frontières historiques : datasets et licences

| Dataset | Couverture | Format | Licence | Verdict |
|---|---|---|---|---|
| [historical-basemaps](https://github.com/aourednik/historical-basemaps) | -123 000 à ~2010 | GeoJSON par tranche | GPL-3.0 (vérifiée) | Oui ; actif ; précision volontairement grossière (BORDERPRECISION), à présenter comme zones d'influence |
| [Cliopatria / Seshat](https://github.com/Seshat-Global-History-Databank/cliopatria) | -3400 à 2024, 1600+ entités, ~14 000 enregistrements datés | GeoJSON (~307 Mo), EPSG:4326 | CC BY 4.0 ([Zenodo v0.1.3](https://zenodo.org/records/14714684)) | Oui, meilleur compromis qualité/licence |
| [OpenHistoricalMap](https://www.openhistoricalmap.org/) | Inégale, très fine par endroits | Modèle OSM (start_date/end_date) | CC0 (août 2022) | Complément, pas une base |
| Seshat Equinox (non géo) | Antiquité à moderne | CSV | CC BY-NC-SA | Non (NC) |
| [GeaCron](http://geacron.com/the-geacron-project/) | -3000 à aujourd'hui | Propriétaire | Propriétaire | Non |
| [Euratlas](https://history.euratlas.net/) | Europe, an 1 à 2000 | Shapefiles vendus | Commerciale | Non |

## 4. Liens entre événements (densités mesurées sur l'arbre événement)

- `P155`/`P156` (précède/suit) : 494 732 événements ; `P361` (partie de) : 739 586 ; `P828`/`P1542` (cause/effet) : 7 413 seulement (trop clairsemées pour un graphe causal dense). Compléments : `P710`, `P1344` (participants), `P793` (événement significatif).
- Les liens entre pages Wikipedia (prop=links, dumps pagelinks) sont du bruit non typé : privilégier les propriétés Wikidata. `P361` pour la hiérarchie guerre/campagne/bataille, `P155`/`P156` pour le chaînage chronologique.

## 5. Dates anciennes dans Wikidata : pièges

Source : [Help:Dates](https://www.wikidata.org/wiki/Help:Dates).

- Précision : 0 = milliard d'années, 3 = million, 6 = millénaire, 7 = siècle, 8 = décennie, 9 = année, 10 = mois, 11 = jour. La valeur stockée contient toujours un jour/mois factices : lire la précision via `psv:`/`wikibase:timePrecision` (le raccourci `wdt:` la masque).
- Années négatives : modèle "1 BCE = année 0" (XSD 1.1), mais le RDF/SPARQL décale d'un an (458 BCE apparaît en `-0457`) alors que le JSON exporte `-0001` pour 1 BCE. Piège de conversion selon le canal d'ingestion.
- Calendriers : valeurs en grégorien proleptique ; le modèle de calendrier (julien par défaut avant 1583) est un calendrier d'affichage.
- Faux positifs : nombreux "1er janvier" (précision année saisie comme jour) : si precision <= 9, tronquer mois/jour.

## 6. Projets similaires

- **[Chronas](https://chronas.org/)** : carte + frise adossée à Wikipedia/Wikidata, frontières par année. Open source ([v1](https://github.com/Chronas), [v2 beta](https://github.com/Chronasorg/chronas)), activité faible. Concurrent le plus proche ; leçon UX : un seul curseur d'année pilote frontières ET marqueurs.
- **[Histropedia](https://histropedia.com/)** : frises depuis Wikidata (pas de carte), dormant ; leur [query timeline](https://js.histropedia.com/apps/query-timeline/) montre une frise branchée sur SPARQL.
- **[OpenHistoricalMap](https://www.openhistoricalmap.org/)** : actif ; leçon : datation par objet plutôt que snapshots annuels.
- **[Running Reality](https://www.runningreality.org/)** : modèle du monde continu, propriétaire ; leçon : la modélisation "événements modifiant un état du monde" est très coûteuse en curation.
- **[Age of Events](https://www.ageofevents.com/)** : entrant récent carte + frise, confirme la viabilité de l'approche.

## Recommandation (reprise dans les ADR 0003 et 0004)

1. Source primaire : Wikidata via QLever ; WDQS pour les petites requêtes fraîches ; dumps JSON à terme si besoin de reproductibilité totale.
2. Sélection : arbre Q1190554 filtré, date (P585/P580) + coordonnées directes (P625) ou héritées du lieu (P276/P625). Corpus ~420 000 événements ; stocker date + précision + calendrier, jamais la date seule.
3. Résumés : API REST Wikipedia (fr, repli en), batch lent, User-Agent identifié, cache persistant, attribution CC BY-SA 4.0. Jamais d'appel client sans cache.
4. Frontières : Cliopatria (CC BY 4.0) en socle, historical-basemaps (GPL-3.0) pour la préhistoire ; éviter GeaCron, Euratlas, Seshat NC.
5. Relations : ingérer P361, P155/P156, P793, P1344 dès l'extraction initiale.
6. Sync mensuelle ou trimestrielle, pipeline idempotent par QID, diff préservant les corrections locales.
