# Strategie de test

Comment Amanogawa teste, et comment ecrire un test de chaque type en suivant
un exemple reel du depot. La regle de couverture et les categories vivent
dans `.claude/rules/testing.md` ; ce document en donne l'application
concrete. Pour l'installation de l'environnement, voir
[getting-started.md](getting-started.md).

## Principes

- **Couverture > 90 % par module**, mesuree par excoveralls et imposee en CI
  (`coveralls.json`, `minimum_coverage: 90`). Sont exclus du calcul :
  `test/support/`, `lib/amanogawa/application.ex`, `deps/`.
- **Chaque issue livre ses tests** : happy path, cas limites, cas d'erreur,
  cas aux bornes.
- **Les fichiers de test refletent exactement `lib/`.** `test/` en est le
  miroir : `lib/amanogawa/atlas/event_queries.ex` est teste par
  `test/amanogawa/atlas/event_queries_test.exs`.
- **Aucun appel reseau en test.** Tout service externe passe par un behaviour
  et un mock Mox, avec des fixtures enregistrees a partir de reponses reelles.
- **`async: true` par defaut**, sauf quand le test touche un etat global.
- **Jamais de `Process.sleep`** dans un test Elixir : `assert_receive`, les
  helpers `Oban.Testing`, ou les helpers d'attente E2E.

## La pyramide de test

| Type | Case / outil | Ce qu'il couvre |
|------|--------------|-----------------|
| Unitaire | `ExUnit.Case` | Logique pure de domaine, sans DB quand c'est possible |
| Property-based | `ExUnitProperties` (StreamData) | Invariants du modele temporel, echelle symlog, parseurs |
| Doctest | `doctest Module` | Fonctions publiques pures aux exemples parlants |
| DataCase | `Amanogawa.DataCase` | Facades de contexte contre PostGIS reel (sandbox) |
| LiveViewTest | `AmanogawaWeb.ConnCase` + `Phoenix.LiveViewTest` | Montage, evenements, navigation de chaque LiveView |
| ConnCase | `AmanogawaWeb.ConnCase` | Endpoints JSON, plugs, pipeline HTTP |
| E2E | `AmanogawaWeb.FeatureCase` (Wallaby) | Parcours critique dans un vrai navigateur |

## Lancer les tests

- `mix test` : toute la suite SAUF les E2E (le tag `:e2e` est exclu par
  defaut dans `test/test_helper.exs`). C'est aussi la derniere etape de
  `mix precommit`.
- `mix test path/to/file_test.exs` : un seul fichier ;
  `mix test path/to/file_test.exs:42` : un seul test par sa ligne.
- `mix test.e2e` : la suite E2E uniquement (`--only e2e` force l'exclusion
  par defaut). Requiert Chrome et chromedriver installes localement.
- `mix coveralls` : la suite avec mesure de couverture ; `mix coveralls.html`
  produit un rapport navigable. Le seuil de 90 % est verifie ici et en CI.

En CI (`.github/workflows/ci.yml`), le job `test` rejoue `mix precommit` puis
`mix coveralls` et `mix deps.audit` ; le job `e2e` lance `mix test.e2e` avec
Chrome preinstalle. Les deux jobs doivent etre verts.

## Fixtures et helpers (`test/support/`)

Compiles uniquement en environnement de test (`elixirc_paths(:test)` dans
`mix.exs`).

- **Cases** : `Amanogawa.DataCase` (sandbox SQL), `AmanogawaWeb.ConnCase`
  (conn de test, plus `log_in_user/2` et `register_and_log_in_user`),
  `AmanogawaWeb.FeatureCase` (session Wallaby, voir la section E2E).
- **Constructeurs de fixtures**, un par schema, seul endroit autorise a
  construire une ligne directement :
  - `Amanogawa.AtlasFixtures` (`fixtures/atlas_fixtures.ex`) :
    `event_fixture/1`, `event_link_fixture/1`, `polity_fixture/1`,
    `border_fixture/1`, plus `unique_qids/1` pour des QID sans collision entre
    fichiers async.
  - `Amanogawa.AccountsFixtures` (`fixtures/accounts_fixtures.ex`) :
    `user_fixture/1`, etc.
  - `Amanogawa.ContributionsFixtures` (`fixtures/contributions_fixtures.ex`).
- **Mocks Mox** : declares dans `test/support/mocks.ex`
  (`SparqlClientMock`, `WikipediaClientMock`, `MagicLinkNotifierMock`,
  `DecisionNotifierMock`, ...).
- **Fixtures de reponses externes** : `test/support/fixtures/sparql/`,
  `.../wikipedia/`, `.../cliopatria/`, `.../time_scale/`, incluant des cas
  hostiles (precision manquante, annees negatives, geometries malformees,
  timeouts SPARQL). Chargees par `Amanogawa.SparqlFixtures` /
  `Amanogawa.WikipediaFixtures`.
- **Generateurs StreamData** partages :
  `test/support/generators/historical_date_generators.ex`
  (`Amanogawa.HistoricalDateGenerators.historical_date/0`, `year/0`,
  `precision/0`).
- **Helpers E2E** : `test/support/e2e_helpers.ex` (`AmanogawaWeb.E2EHelpers`).

Un test qui a besoin d'un evenement ne construit pas une ligne a la main : il
appelle `event_fixture/1` et surcharge ce qui compte pour lui.

## Ecrire un test unitaire ou de property

Pour la logique pure, `use ExUnit.Case, async: true`. Un test de property
ajoute `use ExUnitProperties` et un bloc `property "..." do ... check all`.

Exemple reel, invariant d'alignement de l'histogramme
(`test/amanogawa/atlas_test.exs`) :

```elixir
property "Property (alignment): bucket edges are strictly increasing" do
  scale = TimeScale.default()

  check all buckets <- integer(1..50),
            span <- integer((buckets * 50)..250_000),
            from <- integer(scale.min_year..(scale.max_year - span)),
            max_runs: 25 do
    to = from + span
    result = Atlas.event_histogram(%{from: from, to: to, buckets: buckets})
    edges = [hd(result["buckets"])["from"] | Enum.map(result["buckets"], & &1["to"])]

    assert edges == Enum.sort(edges)
    assert edges == Enum.uniq(edges)
  end
end
```

Les property tests sont obligatoires pour le modele temporel (normalisation
de `HistoricalDate`, aller-retour de l'echelle symlog, invariants de tri) et
pour les parseurs (decodage des resultats SPARQL). On reutilise les
generateurs partages plutot que d'en redefinir.

## Ecrire un doctest

Un exemple `iex>` dans une `@doc` ou `@moduledoc` d'une fonction publique
pure, active par une seule ligne dans le module de test :

```elixir
doctest Amanogawa.Ingestion.SparqlClient.Result
```

Voir `Amanogawa.Ingestion.SparqlClient.Result.decode/1` pour un doctest
reel, et `AmanogawaWeb.Params.EventsQuery.parse_bbox/1` (parsing nominal et
antimeridien). Les doctests documentent et testent en meme temps : reserves
aux fonctions dont l'exemple est parlant.

## Ecrire un test DataCase (PostGIS reel)

`use Amanogawa.DataCase, async: true` fournit la sandbox SQL (chaque test
tourne dans une transaction annulee a la fin), l'import d'Ecto et
`Oban.Testing`. On exerce la facade du contexte contre une vraie base
PostGIS.

```elixir
defmodule Amanogawa.AtlasTest do
  use Amanogawa.DataCase, async: true
  use ExUnitProperties

  import Amanogawa.AtlasFixtures

  test "list_events_geojson excludes events without geometry" do
    kept = event_fixture()
    _dropped = event_fixture(geom: nil)

    %{"features" => features} = Atlas.list_events_geojson(%{...})

    assert Enum.map(features, & &1["properties"]["qid"]) == [kept.qid]
  end
end
```

C'est le niveau ou l'on teste les fragments PostGIS (bbox traversant
l'antimeridien, exclusion des geometries nulles, repli du label fr vers en),
en inserant les donnees par les fixtures.

## Ecrire un test LiveView

`use AmanogawaWeb.ConnCase, async: true` puis `import Phoenix.LiveViewTest`.
On monte la vue avec `live/2`, on assert sur le HTML rendu et sur les
elements, on declenche des evenements et on verifie les `push_patch` / events
pousses. Modele : `test/amanogawa_web/live/explore_live_test.exs`,
`.../contributions_live_test.exs`.

```elixir
test "anonymous visitor sees the chronological feed", %{conn: conn} do
  event = event_fixture(label_fr: "Bataille ancienne")
  override_fixture(event_qid: event.qid, author_id: user_fixture().id)

  {:ok, lv, html} = live(conn, ~p"/contributions")

  assert html =~ "Bataille ancienne"
  assert has_element?(lv, "#contributions-feed")
end
```

Rappel : la LiveView ne fait aucune requete DB dans `mount/3`. Les tests
verifient donc l'etat charge dans `handle_params/3` ou en async.

## Ecrire un test ConnCase (endpoint JSON)

`use AmanogawaWeb.ConnCase, async: true`. On construit une requete, on la
passe dans le pipeline reel, on assert sur le statut et le corps. Modele :
`test/amanogawa_web/controllers/api/event_controller_test.exs`.

```elixir
test "valid params return 200 and a FeatureCollection", %{conn: conn} do
  event_fixture()

  conn =
    conn
    |> unique_conn()
    |> get(~p"/api/events?bbox=-180,-90,180,90&limit=10")

  assert %{"type" => "FeatureCollection"} = json_response(conn, 200)
end
```

Note importante : le rate limiting (Hammer) est un etat global partage (ETS),
non reinitialise par la sandbox entre les tests. Chaque test attribue donc
une IP factice unique a sa conn (`unique_conn/1`, qui pose un `remote_ip`
distinct) pour ne pas polluer le seau de rate limit partage et garder
`async: true` sur. Les tests qui veulent atteindre le chemin 429 epuisent
leur propre IP, jamais la config globale.

## Aucun appel reseau : behaviours + Mox + fixtures

Les pipelines d'ingestion ne dependent que des behaviours
(`Amanogawa.Ingestion.SparqlClient`, `.WikipediaClient`). En test, l'adaptateur
resolu par `Application.get_env` est le mock Mox (`config/test.exs` :
`config :amanogawa, :sparql_client, Amanogawa.Ingestion.SparqlClientMock`).

- On pose une attente par test : `expect(SparqlClientMock, :query, fn _q, _o ->
  {:ok, SparqlFixtures.load("nominal.json")} end)`.
- Les cas hostiles (fixtures `error.html`, `malformed.json`,
  `hostile_bindings.json`, `rate_limited.json`, ...) verifient la robustesse
  de decodage et le mapping vers les erreurs taguees.
- Les adaptateurs eux-memes se testent contre un stub `Req.Test` (pas de
  reseau non plus), avec un backoff quasi nul en test pour ne pas dormir sur
  les scenarios 429 (voir la config `QLever` / `Rest` dans `config/test.exs`).

## Tester le travail Oban

`Amanogawa.DataCase` fait deja `use Oban.Testing, repo: Amanogawa.Repo`. Oban
tourne en mode manuel (`config :amanogawa, Oban, testing: :manual, plugins:
false` dans `config/test.exs`) : les jobs ne s'executent pas via de vraies
files (pas de course avec un poller). On assert le job enfile
(`assert_enqueued`), ou on execute la logique directement avec
`perform_job(Worker, args)`. Le plan de pagination des workers est reduit en
test (`page_size: 3`, `max_qid: 20`, ...) pour exercer plusieurs pages sur de
petites fixtures.

## Suite E2E (Wallaby + Chrome)

La suite `test/e2e/` pilote un vrai Chrome headless via Wallaby et
chromedriver, pour couvrir les contrats hook <-> LiveView qu'aucun test
in-process ne voit (rendu WebGL, evenements DOM et pointeur reels,
`matchMedia`). Elle est taguee `:e2e` (via `AmanogawaWeb.FeatureCase`),
exclue de `mix test`, lancee par `mix test.e2e`. Un developpeur qui ne lance
jamais les E2E n'a pas besoin de Chrome (la dependance Wallaby est
`runtime: false`, jamais demarree par `mix test`).

### Configuration Chrome (`config/test.exs`)

- Un vrai listener HTTP : `config :amanogawa, AmanogawaWeb.Endpoint, server:
  true`, port 4002. Le reste de la suite (conn in-process) l'ignore.
- La sandbox SQL est montee sur l'endpoint (`Phoenix.Ecto.SQL.Sandbox`, gate
  par `config :amanogawa, sql_sandbox: true`) pour que les requetes HTTP du
  navigateur atteignent la meme connexion sandboxee que le test.
- Chrome en mode headless moderne : `--headless=new` (pas le legacy
  `--headless`, dont la pile de rendu ne cree pas de contexte WebGL logiciel).
- WebGL logiciel sur les runners sans GPU : `--use-angle=swiftshader` et
  `--enable-unsafe-swiftshader` (Chrome 129+ verrouille le fallback logiciel
  derriere ce flag explicite). Sans contexte WebGL, MapLibre refuse de
  construire la carte.
- Overrides machine-locaux optionnels : `CHROMEDRIVER_PATH` et
  `CHROME_BINARY` pour pointer une paire Chrome for Testing telechargee
  directement (contourne un rejet Gatekeeper de la binaire du cask Homebrew
  sur macOS). CI et setups normaux laissent les deux vides.
- `max_wait_time: 12_000` : plus large que le defaut de 3000 ms, car un
  changement de theme (rechargement de style + refetch d'evenements) sous
  swiftshader peut legitimement durer plus longtemps en CI.

### Contourner le canvas WebGL non assertable

Le rendu MapLibre est un canvas WebGL : on ne peut pas assert sur son
contenu. Les contrats se verifient donc par l'URL, le DOM des panneaux et
bulles, et par des temoins exposes en JS.

- **Temoin `window.__amanogawaE2E__`** : un objet de test pose par le MapHook
  UNIQUEMENT quand `#map` porte `data-e2e-test-api="true"`, ce qui n'arrive
  que si `config :amanogawa, :expose_e2e_test_api` vaut `true`, pose
  seulement dans `config/test.exs`. En dev et prod, l'objet n'existe pas. Il
  permet de declencher exactement l'intention `select_event` /
  `deselect_event` qu'un clic reel sur un marqueur enverrait, sans dependre du
  hit-testing du canvas sous Chrome headless. Il expose aussi `mapLoaded()` et
  des compteurs de fetch.
- **Attributs `data-*`** sur `#map` comme temoins lisibles :
  `data-events-loaded`, `data-events-fetch-count`, `data-map-degraded`.

### Helpers E2E (`test/support/e2e_helpers.ex`)

- `wait_for_map_ready/1` : attend `#map[data-events-loaded='true']`, echoue
  vite et clairement si la carte a degrade faute de WebGL
  (`data-map-degraded="true"`) ou si le layout a donne au `#map` une taille
  nulle.
- `wait_for_map_rendered/2` : attend que MapLibre se declare `loaded()` (via
  le temoin), requis avant tout scenario qui pilote le canvas avec un vrai
  curseur (hover).
- `select_event/2`, `deselect_event/1`, `pick_position/3` : declenchent les
  intentions via le temoin.
- `retry_stale/3` : reexecute une action (quelques tentatives, court delai
  entre elles) qui a leve `Wallaby.StaleReferenceError`, une course reelle du
  navigateur ou un patch LiveView de fond remplace un noeud au moment ou un
  clic ou un `fill_in` le vise. Absente de `Phoenix.LiveViewTest`.
- `emulate_dark_mode/1` : bascule `prefers-color-scheme` via CDP.

### Notifier reel et boite Swoosh partagee en E2E

En E2E, le clic reel qui declenche l'envoi d'un mail (lien magique, decision
de moderation) tourne dans le processus de la LiveView, jamais dans le
processus de test : un mock Mox (mode prive) ne fonctionne donc pas.
`AmanogawaWeb.FeatureCase` bascule les cles `:magic_link_notifier` et
`:decision_notifier` vers les vrais notifiers (`.MagicLinkNotifier.Mailer`,
`.DecisionNotifier.Email`), qui envoient par `Amanogawa.Mailer`
(`Swoosh.Adapters.Test`). Le test relit le mail via
`share_swoosh_mailbox/0`, qui route les mails vers la boite du processus de
test courant (`Application.put_env(:swoosh, :shared_test_process, self())`),
appele depuis un `setup` par test (jamais `setup_all`). `mix test.e2e`
tournant dans un BEAM separe de `mix test`, ces `put_env` ne fuient jamais
vers les autres suites.

### Sessions multiples

`@sessions N` est un attribut ExUnit "registered" (comme `@tag`) : il ne
s'applique qu'au `feature/3` qui suit immediatement. Le redeclarer devant
CHAQUE scenario a deux sessions, jamais une seule fois en tete de module,
sinon le scenario suivant recoit un `%{session: ...}` singulier et casse sur
le pattern `%{sessions: [...]}`.

## Bonnes pratiques

- **`async: true` par defaut**, `async: false` uniquement si le test mute un
  etat global (config partagee, niveau Logger).
- **Aucun `Process.sleep`** dans un test Elixir : `assert_receive`, helpers
  `Oban.Testing`, helpers d'attente E2E (les seuls sleeps du depot sont dans
  les boucles de retry de `e2e_helpers.ex`, face a un vrai navigateur).
- **IP factice unique** pour tout test qui traverse un rate limiter Hammer,
  afin de ne pas polluer le seau ETS partage (`unique_conn/1`,
  `unique_ip/0`).
- **Antidater `inserted_at` pour tester un ordre** plutot que de dormir :
  `Ecto.Changeset.change(row, inserted_at: DateTime.add(ref, -60, :second))`
  puis `Repo.update!/1` (voir `contributions_live_test.exs`,
  `accounts_test.exs`).
- **Ne jamais `Application.put_env` une cle de config partagee sous
  `async: true`** : preferer epuiser une cle propre (IP, auteur unique) ou
  passer le test en `async: false` avec une limite abaissee localement.
- **Fixtures pour toute donnee** : un constructeur canonique par schema, on
  ne construit jamais une ligne a la main hors des modules de fixtures.
