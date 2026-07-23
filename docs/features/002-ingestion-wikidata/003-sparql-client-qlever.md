# Issue #008 -- SparqlClient : behaviour et adaptateur QLever

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #002

---

## Contexte

L'extraction Wikidata passe par SPARQL. L'ADR 0003 retient le endpoint QLever (`https://qlever.dev/api/wikidata`) pour les extractions massives : il exécute en quelques secondes les requêtes `P31/P279*` globales qui timeoutent sur le WDQS officiel. Conformément à l'architecture hexagonale (`.claude/rules/architecture.md`), l'accès au système externe se fait par un port : un behaviour `Amanogawa.Ingestion.SparqlClient` défini dans le domaine, avec un adaptateur de production Req. Les consommateurs (décodeur #009, workers #010/#011) ne dépendent que du behaviour ; les tests utilisent un mock Mox.

L'adaptateur est la seule frontière transport : il ne laisse fuir ni statut HTTP ni forme JSON brute. Il retourne soit une structure de résultat SPARQL normalisée, soit une erreur taguée. Il applique l'étiquette Wikimedia (`.claude/rules/ethics.md`) : User-Agent identifié sur chaque requête, timeouts explicites, backoff sur 429.

Cette issue ne contient aucune requête métier : les templates SPARQL arrivent en #009. Elle livre le canal fiable et testé par lequel toutes les requêtes passeront.

## User Story

> En tant que développeur du pipeline d'ingestion, je veux un client SPARQL derrière un behaviour, avec erreurs taguées et étiquette Wikimedia respectée, afin d'exécuter les extractions massives sur QLever et de tester tous les consommateurs sans réseau.

---

## Tâches

- [ ] Définir le behaviour `Amanogawa.Ingestion.SparqlClient` :
  - `@callback query(sparql :: String.t(), opts :: keyword()) :: {:ok, SparqlClient.Result.t()} | {:error, error()}`
  - type `error` tagué : `{:http_error, status}`, `{:rate_limited, retry_after_seconds | nil}`, `:timeout`, `{:transport_error, reason}`, `{:decode_error, reason}`.
- [ ] Définir la structure `Amanogawa.Ingestion.SparqlClient.Result` : `variables` (liste de noms) et `bindings` (liste de maps `var => %{value: String.t(), type: :uri | :literal | :bnode, datatype: String.t() | nil, lang: String.t() | nil}`), décodée depuis le format standard `application/sparql-results+json`.
- [ ] Implémenter l'adaptateur `Amanogawa.Ingestion.SparqlClient.QLever` avec Req :
  - POST sur l'URL configurée (défaut `https://qlever.dev/api/wikidata`), corps `application/sparql-query`, en-tête `Accept: application/sparql-results+json` ;
  - User-Agent construit dynamiquement : `Amanogawa/<version> (https://github.com/Thibault-Santonja/Amanogawa; thibault.santonja@gmail.com)`, version lue depuis `Application.spec(:amanogawa, :vsn)` ;
  - timeouts explicites et configurables (connexion ~15 s, réception ~120 s, les extractions paginées restent longues) ;
  - sur 429 : backoff exponentiel borné (3 tentatives max) honorant l'en-tête `Retry-After` quand présent ; au-delà, retour `{:error, {:rate_limited, retry_after}}` ;
  - mapping exhaustif des échecs vers les erreurs taguées ; aucune exception ne traverse l'adaptateur (`try/rescue` autorisé ici, frontière système, toujours converti en erreur taguée).
- [ ] Configuration : `config :amanogawa, :sparql_client, Amanogawa.Ingestion.SparqlClient.QLever` (adapter résolu à l'exécution par les consommateurs) ; URL et timeouts dans la config de l'adaptateur ; en environnement test, `Amanogawa.Ingestion.SparqlClientMock`.
- [ ] Déclarer le mock Mox (`Mox.defmock(Amanogawa.Ingestion.SparqlClientMock, for: Amanogawa.Ingestion.SparqlClient)`) dans `test/support/mocks.ex`.
- [ ] Enregistrer des fixtures réelles dans `test/support/fixtures/sparql/` (réponses `application/sparql-results+json` de QLever) : un résultat nominal avec dates et coordonnées WKT, un résultat vide, un JSON malformé, une page d'erreur HTML (cas où le endpoint répond hors contrat). Documenter dans un `README.md` du dossier la requête et la date de capture de chaque fixture.
- [ ] Helper de test `sparql_fixture/1` chargeant une fixture et la présentant comme retour du mock (réutilisé par #009, #010, #011).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : l'adaptateur décode une fixture nominale en `%Result{}` (variables et bindings corrects, datatype et lang préservés) ; le User-Agent et l'Accept attendus sont présents sur la requête (vérifiés via `Req.Test`).
- [ ] **Edge case** : résultat vide (0 binding) retourne `{:ok, %Result{bindings: []}}` ; binding sans datatype ni lang ; valeurs littérales contenant des caractères non ASCII.
- [ ] **Error case** : statut 500 -> `{:error, {:http_error, 500}}` ; corps non JSON -> `{:error, {:decode_error, _}}` ; timeout de réception -> `{:error, :timeout}` ; erreur de connexion -> `{:error, {:transport_error, _}}`.
- [ ] **Limit case** : 429 avec `Retry-After` -> nouvelles tentatives avec délais croissants puis succès ; 429 persistant au-delà du maximum -> `{:error, {:rate_limited, n}}` ; réponse volumineuse (fixture de plusieurs milliers de bindings) décodée sans dégradation.

### Property-based tests (si applicable)

- [ ] **Property** : le décodage `sparql-results+json` -> `%Result{}` ne perd aucun binding et ne lève jamais sur des documents générés conformes au format (générateur StreamData de résultats SPARQL synthétiques).

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (module d'accès réseau).

### Tests d'intégration

- [ ] **Intégration** : via `Req.Test` (stub du transport, aucun réseau), scénario complet POST -> décodage -> `%Result{}` avec la fixture réelle QLever ; scénario 429 puis 200 vérifiant le backoff sans `Process.sleep` dans les assertions.

### Tests end-to-end (si applicable)

- [ ] **E2E** : non applicable. Aucun test ne contacte QLever ni le WDQS.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/ingestion/sparql_client.ex` (behaviour + types + struct `Result`)
  - `lib/amanogawa/ingestion/sparql_client/qlever.ex`
  - `config/config.exs`, `config/test.exs` (résolution de l'adaptateur)
  - `test/support/mocks.ex`
  - `test/support/fixtures/sparql/` (fixtures + `README.md` de provenance)
  - `test/amanogawa/ingestion/sparql_client/qlever_test.exs`
- **Documentation de référence** : ADR 0003, `.claude/rules/architecture.md` (ports et adaptateurs), `.claude/rules/ethics.md` (étiquette Wikimedia), `.claude/skills/wikidata-query/SKILL.md`, [SPARQL 1.1 Query Results JSON Format](https://www.w3.org/TR/sparql11-results-json/), documentation Req (retry, Req.Test).
- **Compétences requises** : Req (options de retry, plug de test), Mox, format de résultats SPARQL JSON.
- **Points d'attention** :
  - Meta-règle projet : Req uniquement, pas de httpoison/tesla/httpc.
  - Le behaviour reste agnostique du endpoint : le WDQS officiel pourra devenir un second adaptateur plus tard, sans toucher les consommateurs. Ne pas coder de logique spécifique QLever hors de l'adaptateur.
  - Ne jamais logger le corps complet des requêtes ou réponses en production (volumes) ; logger statut, durée et taille.
  - Le backoff de l'adaptateur couvre les erreurs transitoires intra-requête ; la reprise de plus haut niveau (pages, runs) relève du worker #010.
  - Capturer les fixtures avec une vraie requête une seule fois (curl ou livebook jetable), jamais depuis la suite de tests.
