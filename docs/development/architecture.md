# Architecture

Ce document décrit l'architecture réelle d'Amanogawa telle qu'elle est implémentée : la vue en couches, les bounded contexts, les frontières hexagonales, le modèle de données clé, les flux de bout en bout et la liste des décisions structurantes (ADR).

Pour prendre en main l'environnement, voir [getting-started.md](getting-started.md). Pour la marche à suivre concrète quand on ajoute une fonctionnalité, voir [adding-a-feature.md](adding-a-feature.md). Pour savoir précisément quel fichier ouvrir, voir [codebase-map.md](codebase-map.md).

## Vue d'ensemble en couches

Amanogawa est une application Phoenix 1.8 LiveView. Trois couches, une direction de dépendance stricte (la couche web appelle le domaine, jamais l'inverse ; le front appelle la couche web via WebSocket LiveView et via des endpoints JSON dédiés).

```
                        NAVIGATEUR
   +-----------------------------------------------------------+
   |  assets/js                                                |
   |    hooks/map_hook.js (MapLibre GL JS)                     |
   |    hooks/timeline.js (d3 scale/zoom)                      |
   |    lib/, map/  (echelle symlog, gradient, layers, bbox)   |
   +-----------------------------------------------------------+
        |   ^                                  |   ^
  WebSocket |  push_event / handle_event   fetch|  JSON (read-only)
  LiveView  |  (intentions, bornes legeres)     |  GET /api/events, /borders
        v   |                                  v   |
   +-----------------------------------------------------------+
   |  lib/amanogawa_web  (couche web)                          |
   |    router.ex, endpoint.ex                                 |
   |    live/       LiveViews (etat applicatif)                |
   |    controllers/api/  endpoints JSON volumineux            |
   |    params/     validation et bornage stricts              |
   |    plugs/      CSP, RateLimit, SetLocale                  |
   |    components/ EventPanel, TimeLegend, layouts            |
   |    user_auth.ex, scope, attribution                       |
   +-----------------------------------------------------------+
        |   appels de facades uniquement (jamais Repo direct)
        v
   +-----------------------------------------------------------+
   |  lib/amanogawa  (couche domaine, bounded contexts)        |
   |                                                           |
   |   Atlas          Ingestion       Accounts   Contributions|
   |   (read model)   (pipelines)     (auth)     (edition)     |
   |                                                           |
   |   shared kernel : HistoricalDate, WikimediaUrl           |
   +-----------------------------------------------------------+
        |
        v
   +-----------------------------------------------------------+
   |  PostgreSQL + PostGIS                                      |
   |  schemas PG : atlas | ingestion | accounts | contributions|
   +-----------------------------------------------------------+
```

- Domaine : [`lib/amanogawa/`](../../lib/amanogawa) contient la logique métier organisée en bounded contexts. Aucun appel `Repo` n'existe hors d'un contexte.
- Web : [`lib/amanogawa_web/`](../../lib/amanogawa_web) contient les LiveViews, les controllers d'API JSON, les composants, les params validés, les plugs et l'authentification. La couche web n'appelle que les façades de contexte.
- Front : [`assets/js/`](../../assets/js) contient les hooks LiveView vanilla (MapLibre, d3) et des modules purs testés sous `node:test`.

La supervision ([`lib/amanogawa/application.ex`](../../lib/amanogawa/application.ex)) démarre `AmanogawaWeb.Telemetry`, `Amanogawa.Repo`, `Oban`, l'`Amanogawa.Alerting.ErrorReporter` et `AmanogawaWeb.Endpoint`, stratégie `:one_for_one`.

## Bounded contexts

Principe (voir [`.claude/rules/architecture.md`](../../.claude/rules/architecture.md) et le CLAUDE.md racine) :

- Chaque contexte expose UN module façade public (`Amanogawa.Atlas`, `Amanogawa.Ingestion`, `Amanogawa.Accounts`, `Amanogawa.Contributions`). La façade est mince : des fonctions qui délèguent aux modules internes.
- Les modules internes (schémas, requêtes, services) sont privés au contexte. On ne les appelle jamais depuis un autre contexte ni depuis la couche web.
- La couche web n'appelle que les façades. Aucun appel `Repo` hors des contextes.
- Un besoin de données inter-contexte passe par la façade, même si cela paraît indirect.

Les quatre contextes :

| Contexte | Façade | Emplacement | Rôle |
|----------|--------|-------------|------|
| Atlas | `Amanogawa.Atlas` | [`lib/amanogawa/atlas/`](../../lib/amanogawa/atlas) | Read model servi à l'UI : events, event_links, polities, borders |
| Ingestion | `Amanogawa.Ingestion` | [`lib/amanogawa/ingestion/`](../../lib/amanogawa/ingestion) | Pipelines d'import Wikidata / Wikipedia / Cliopatria (Oban) |
| Accounts | `Amanogawa.Accounts` | [`lib/amanogawa/accounts/`](../../lib/amanogawa/accounts) | Utilisateurs, authentification par magic link, sessions révocables |
| Contributions | `Amanogawa.Contributions` | [`lib/amanogawa/contributions/`](../../lib/amanogawa/contributions) | Édition collaborative, modération, conflits de sync |

### Séparation par schéma PostgreSQL

Un schéma PG par contexte. Chaque schéma Ecto déclare `@schema_prefix`. Les clés étrangères inter-schémas PG ne sont autorisées qu'à l'intérieur d'un même contexte ; entre contextes, il n'existe aucune FK (l'existence des lignes est vérifiée à l'application, jamais contrainte en base).

| Schéma PG | Tables | `@schema_prefix` |
|-----------|--------|------------------|
| `atlas` | `events`, `event_links`, `polities`, `borders` | `atlas` |
| `ingestion` | `sync_runs`, jobs Oban | `ingestion` |
| `accounts` | `users`, `magic_link_tokens`, `session_tokens` | `accounts` |
| `contributions` | `overrides`, `revisions`, `conflicts` | `contributions` |

La migration [`priv/repo/migrations/20260723090000_create_postgis_and_schemas.exs`](../../priv/repo/migrations) crée l'extension PostGIS et les schémas ; les migrations suivantes créent les tables dans le bon schéma.

Point notable : Ingestion et Contributions écrivent dans le corpus Atlas UNIQUEMENT via la façade `Amanogawa.Atlas` (par exemple `upsert_events/1`, `apply_field_override/3`, `create_contributed_event/1`). Il n'existe aucune FK entre `contributions` et `atlas` : la seule porte d'entrée est la façade (ADR 0009).

## Architecture hexagonale (ports et adaptateurs)

Les systèmes externes sont accédés à travers des behaviours définis dans le domaine ; les adaptateurs de production vivent à côté du behaviour ; les tests utilisent des mocks Mox du behaviour. Aucun détail de transport (statut HTTP, forme JSON) ne fuit au-delà de l'adaptateur : les adaptateurs renvoient des structs de domaine ou des erreurs taguées.

| Behaviour (port) | Callback principal | Adaptateur de production | Rôle |
|------------------|--------------------|--------------------------|------|
| [`Amanogawa.Ingestion.SparqlClient`](../../lib/amanogawa/ingestion/sparql_client.ex) | `query/2` | `SparqlClient.QLever` | Requêtes SPARQL vers QLever (extractions massives Wikidata) |
| [`Amanogawa.Ingestion.WikipediaClient`](../../lib/amanogawa/ingestion/wikipedia_client.ex) | `fetch_summary/2` | `WikipediaClient.REST` | Résumés d'articles via l'API REST Wikipedia |
| [`Amanogawa.Accounts.MagicLinkNotifier`](../../lib/amanogawa/accounts/magic_link_notifier.ex) | `deliver/3` | `MagicLinkNotifier.Mailer` | Envoi du mail de connexion |
| [`Amanogawa.Contributions.DecisionNotifier`](../../lib/amanogawa/contributions/decision_notifier.ex) | `deliver/...` | `DecisionNotifier.Email` | Notification d'acceptation ou de rejet d'un override |
| [`Amanogawa.Alerting.Notifier`](../../lib/amanogawa/alerting/notifier.ex) | `deliver/2` | `Notifier.Mailer` | Alerting sobre par mail |
| [`Amanogawa.Alerting.Clock`](../../lib/amanogawa/alerting/clock.ex) | `now_ms/0` | `Clock.System` | Horloge injectable (tests de fenêtre glissante) |
| [`Amanogawa.HealthCheck`](../../lib/amanogawa/health_check.ex) | `check/0` | `HealthCheck.Repo` | Sonde de liveness |

Le behaviour [`Amanogawa.Ingestion.Workers.PagedImport`](../../lib/amanogawa/ingestion/workers/paged_import.ex) est un port interne : il factorise l'orchestration paginée partagée par `ImportEvents` et `ImportLinks` (`page_query/1`, `apply_page/3`, `fetched_count_key/0`).

Le choix de l'adaptateur est fait par configuration (mock en test, adaptateur réel en dev et prod). Voir [testing.md](testing.md) pour l'usage de Mox.

## Modèle de données clé

### HistoricalDate (shared kernel)

[`Amanogawa.HistoricalDate`](../../lib/amanogawa/historical_date.ex) est le seul module partagé entre contextes (shared kernel, hors des quatre bounded contexts). C'est un embedded schema, pas un type `date` PostgreSQL (qui ne descend pas sous l'an -4713 et supposerait un calendrier moderne, cf. ADR 0006).

- `year` : entier signé, convention astronomique (1 BCE = année 0).
- `month`, `day` : nullables, présents seulement si `precision >= 10`.
- `precision` : échelle Wikidata 0 à 11 (0 = milliard d'années, 11 = jour).
- `calendar` : `:gregorian` ou `:julian`, pour l'affichage seulement.

En base, les dates sont stockées en colonnes plates pour l'indexation et le tri : `begin_year`, `begin_month`, `begin_day`, `begin_precision`, `begin_calendar`, et les équivalents `end_*`. La normalisation Wikidata (décalage RDF des années négatives, troncature des faux 1er janvier) se fait dans l'adaptateur d'ingestion ([`Amanogawa.HistoricalDate.Wikidata`](../../lib/amanogawa/historical_date/wikidata.ex)), l'affichage respectant toujours la précision ([`Amanogawa.HistoricalDate.Formatter`](../../lib/amanogawa/historical_date/formatter.ex)).

### Géométries PostGIS, GeoJSON à la bordure

SRID 4326 partout. Les types PostGIS restent en base, le GeoJSON n'apparaît qu'à la bordure (endpoints JSON), cf. ADR 0007.

- `atlas.events.geom` : `geometry(Point, 4326)`. `location_source` trace la provenance (`:direct`, `:place`, `:country`, `:contribution`).
- `atlas.borders` : `geom`, plus deux géométries simplifiées à l'import (`geom_medium`, `geom_low`) pour tenir le budget de payload. `from_year` / `to_year` bornent la période d'existence.

Les fragments PostGIS (`ST_AsGeoJSON`, `ST_Intersects`, `ST_MakeEnvelope`, `width_bucket`, `ST_SimplifyPreserveTopology`, ...) sont concentrés dans un seul module de requêtes par entité : [`Amanogawa.Atlas.EventQueries`](../../lib/amanogawa/atlas/event_queries.ex) et [`Amanogawa.Atlas.BorderQueries`](../../lib/amanogawa/atlas/border_queries.ex).

### Contributions résolues à l'écriture (ADR 0009)

La valeur affichée (Wikidata ou corrigée) est calculée À L'ÉCRITURE, jamais à la lecture. Il n'existe aucune vue matérialisée ni jointure sur le chemin de lecture chaud (viewport, histogramme, API publique).

- `contributions.overrides` porte une ligne par champ corrigé (`event_qid`, `field`, `proposed_value`, `source`, `status`), sans FK vers `atlas.events`.
- À l'acceptation, `Amanogawa.Contributions.accept_override/3` appelle `Amanogawa.Atlas.apply_field_override/3`, seule porte d'entrée : la valeur corrigée est écrite DANS les colonnes métier existantes de `atlas.events` (`label_fr`, `begin_year`, `geom`, ...) et le nom du champ est ajouté au tableau `atlas.events.overridden_fields`. Tout lecteur existant sert la valeur corrigée gratuitement.
- La valeur Wikidata est snapshotée dans l'override (`wikidata_value_at_acceptance`), ce qui rend la correction réversible (`release_field_override/3`).
- L'upsert de sync (`upsert_events/1`) est un remplacement conditionnel colonne par colonne : un champ marqué dans `overridden_fields` n'est jamais réécrit par la sync, les autres champs de la ligne continuent de se synchroniser.
- Un événement d'origine communautaire entre dans `atlas.events` avec un identifiant local `L<uuid hex>` dans la colonne `qid` (jamais en collision avec `Q\d+`) et une colonne `origin` (`:wikidata` ou `:contribution`).

Les champs corrigeables sont énumérés dans [`Amanogawa.Atlas.OverridableField`](../../lib/amanogawa/atlas/overridable_field.ex) : `:label_fr`, `:label_en`, `:begin_date`, `:end_date`, `:position`.

## Flux d'une requête d'exploration (de bout en bout)

Deux canaux coexistent volontairement (ADR 0005, ADR 0007) : LiveView (WebSocket) porte l'état applicatif et des intentions légères ; les endpoints JSON dédiés portent les gros volumes géo. Chacun fait ce pour quoi il est bon.

```
1. URL             GET /?from=-500&to=500&z=3&lat=..&lng=..&selected_qid=Q123
                        |
2. LiveView        AmanogawaWeb.ExploreLive.handle_params/3
                     -> AmanogawaWeb.Params.ExploreParams.parse/1  (bornage strict)
                     -> assign(from, to, z, lat, lng, selected_qid, ...)
                     -> push_event("set_time_window", %{from, to})   (serveur -> hook)
                     -> push_event("set_view", %{z, lat, lng})
                        |
3. Hooks (WS)      MapHook / TimelineHook recoivent les events LiveView,
                   recalculent la fenetre et la camera
                        |
4. Volumes (JSON)  MapHook calcule la bbox du viewport et fetch en HTTP :
                     GET /api/events?bbox=&from=&to=&limit=
                     GET /api/borders?year=
                   -> AmanogawaWeb.Controllers.Api.EventController / BorderController
                     -> Params (EventsQuery, BorderQuery) valident et bornent
                     -> Amanogawa.Atlas.list_events_geojson/1 / list_borders_geojson/1
                     -> EventQueries / BorderQueries (PostGIS, GeoJSON en sortie)
                        |
5. Rendu           MapLibre stylise les sources GeoJSON par expressions ;
                   d3 rend la frise et l'histogramme.
```

Ce qui passe par le WebSocket LiveView : l'état (fenêtre temporelle, caméra, sélection, mode de proposition), sous forme d'intentions et de bornes légères (par exemple `map_moved`, `select_event`, `select_time_window` du hook vers le serveur ; `set_time_window`, `set_view`, `event_selected` du serveur vers le hook).

Ce qui passe par les endpoints JSON : les FeatureCollections GeoJSON volumineuses (événements du viewport, frontières de l'année), read-only, rate-limitées par IP (`AmanogawaWeb.Plugs.RateLimit` sur le pipeline `:api`). On ne fait jamais transiter ces volumes par des diffs LiveView (cela saturerait le canal WebSocket, ADR 0005).

La sélection d'un événement, elle, passe par LiveView (`select_event` du hook, `push_patch` de l'URL, `handle_params` qui charge le détail via `Amanogawa.Atlas.get_event_summary/1`) et alimente le composant `EventPanel`.

## Pipeline d'ingestion

L'ingestion est une suite de jobs Oban idempotents, jamais des GenServers avec timers (iron law : Oban pour le travail de fond).

```
Oban Cron mensuel (ScheduledSync, ADR 0003)
    |
    v
ImportEvents  --\
ImportLinks    --> PagedImport (behaviour partage : pagination)
                     |
                     v
                 SparqlClient.query/2  ->  QLever (SPARQL)
                     |
                     v
                 Wikidata.EventDecoder / LinkDecoder (structs de domaine)
                     |  (normalisation des dates : HistoricalDate.Wikidata)
                     v
                 Amanogawa.Atlas.upsert_events/1 / upsert_event_links/1
                     |  (upsert par QID, remplacement conditionnel des
                     |   colonnes marquees dans overridden_fields)
                     v
EnrichSummaries -> WikipediaClient.fetch_summary/2 -> Atlas.put_event_summary/...
```

Détails :

- Extraction depuis l'arbre Wikidata Q1190554 filtré par [`Amanogawa.Ingestion.Wikidata.Blocklist`](../../lib/amanogawa/ingestion/wikidata/blocklist.ex) ; les requêtes SPARQL sont construites dans [`Amanogawa.Ingestion.Wikidata.Templates`](../../lib/amanogawa/ingestion/wikidata/templates.ex).
- Résolution des coordonnées en cascade (P625 direct, sinon P276 vers P625), provenance tracée dans `location_source`.
- Enrichissement paresseux et en batch lent des résumés Wikipedia (fr avec repli en), avec cache persistant et attribution CC BY-SA 4.0.
- Frontières : import de fichiers GeoJSON Cliopatria (socle mondial) et historical-basemaps (période antérieure à -3400), streaming borné en mémoire via [`Amanogawa.Ingestion.Borders.GeojsonStream`](../../lib/amanogawa/ingestion/borders/geojson_stream.ex), simplification à l'import. Déclenché par les mix tasks `amanogawa.import.cliopatria` et `amanogawa.import.historical_basemaps`.
- L'état d'un import est journalisé dans `ingestion.sync_runs` ([`Amanogawa.Ingestion.SyncRun`](../../lib/amanogawa/ingestion/sync_run.ex)) ; `run_guard` capture les exceptions en dernière ligne.

Coexistence sync / overrides : à chaque lot synchronisé, `Amanogawa.Contributions.record_sync_divergences/1` compare le lot entrant aux overrides `:accepted` et journalise les divergences réelles dans `contributions.conflicts` (examinées sur `/relecture/conflits`).

## Authentification

Sans mot de passe, par magic link (F07). Le module central de plomberie de session est [`AmanogawaWeb.UserAuth`](../../lib/amanogawa_web/user_auth.ex).

- `Amanogawa.Accounts.generate_magic_link_token/1` puis `deliver_magic_link/4` envoient un lien à usage unique ; `redeem_magic_link_token/1` le consomme.
- La session est portée par un `session_token` révocable : `list_session_tokens/1`, `revoke_session_token/2`, `renew_session_token/1`, `delete_session_token/1`.
- Le contexte de sécurité de chaque requête est un [`Amanogawa.Accounts.Scope`](../../lib/amanogawa/accounts/scope.ex) assigné à `@current_scope` par le plug `fetch_current_scope_for_user` (jamais un `nil` nu : utilisateur possiblement `nil`).
- Les rôles : `Amanogawa.Accounts.reviewer?/1` distingue les relecteurs. Le routeur superpose trois live_sessions et pipelines : `:current_user` (lecture publique), `:require_authenticated_user` (`/compte`), `:require_reviewer` (`/relecture`, `/relecture/conflits`).
- RGPD : `export_user_data/1` (portabilité) et `delete_user/1` côté Accounts ; côté Contributions, `anonymize_user/1` anonymise les contributions plutôt que de les supprimer (article 17.3.d, historique public cohérent).

Éthique et sécurité (ADR 0008) : CSP stricte ([`AmanogawaWeb.Plugs.ContentSecurityPolicy`](../../lib/amanogawa_web/plugs/content_security_policy.ex)), zéro tracking tiers, pages statiques servies sans session (pipeline `:static_page`), un seul cookie de session strictement nécessaire sur `/` (CSRF du handshake WebSocket LiveView).

## Rendu front

Pas de framework JS : des hooks LiveView vanilla, plus des modules purs testés sous `node:test`.

- Carte : [`assets/js/hooks/map_hook.js`](../../assets/js/hooks/map_hook.js) pilote MapLibre GL JS. Les sources GeoJSON sont stylées par expressions (gradient temporel des marqueurs, transparence des frontières). La construction des couches est déportée dans des modules purs sans dépendance MapLibre : [`map/event_layers.js`](../../assets/js/map/event_layers.js), [`map/border_layers.js`](../../assets/js/map/border_layers.js), [`map/link_layers.js`](../../assets/js/map/link_layers.js), plus [`map/bbox.js`](../../assets/js/map/bbox.js), [`map/style_utils.js`](../../assets/js/map/style_utils.js) et [`map/hover_card.js`](../../assets/js/map/hover_card.js).
- Frise : [`assets/js/hooks/timeline.js`](../../assets/js/hooks/timeline.js) utilise d3 (modules scale/zoom/selection uniquement) avec une échelle symlog.
- Échelle symlog partagée Elixir / JS : [`Amanogawa.Atlas.TimeScale`](../../lib/amanogawa/atlas/time_scale.ex) et [`assets/js/lib/time_scale.js`](../../assets/js/lib/time_scale.js) implémentent la même échelle, vérifiées contre une fixture d'ancres commune [`test/support/fixtures/time_scale/anchors.json`](../../test/support/fixtures/time_scale/anchors.json) (positions calculées une fois, jamais régénérées).
- Gradient temporel : source unique dans des tokens CSS (`--time-start-color`, `--time-end-color`, variantes claires et sombres dans `assets/css/app.css`), convention d'interpolation unique dans [`assets/js/lib/time_gradient.js`](../../assets/js/lib/time_gradient.js), consommée par les marqueurs MapLibre, l'histogramme et la légende ([`AmanogawaWeb.TimeLegend`](../../lib/amanogawa_web/components/time_legend.ex)). Les tokens sont résolus en `rgb()` avant d'être passés à MapLibre (son parseur ne connaît pas `oklch()`).
- Fluidité du drag : la frise diffuse un `CustomEvent` DOM `amanogawa:time-window-preview` (constante `TIME_WINDOW_PREVIEW_EVENT`, définie dans `time_gradient.js`) que le hook carte consomme pour recolorer immédiatement, sans round-trip serveur avant le debounce.
- Convention des events LiveView de fenêtre : `set_time_window` = serveur vers hook, `select_time_window` = hook vers serveur.

Les deux hooks sont enregistrés dans [`assets/js/app.js`](../../assets/js/app.js). MapLibre et d3 sont vendorés (pas de CDN, CSP stricte).

## Décisions structurantes (ADR)

Les décisions d'architecture sont consignées dans [`docs/adr/`](../../docs/adr). Ordre chronologique :

1. [ADR 0001](../../docs/adr/0001-reecriture-elixir-phoenix-liveview.md) : réécriture en Elixir / Phoenix 1.8 LiveView (abandon du prototype Django/React).
2. [ADR 0002](../../docs/adr/0002-reutilisation-depot-purge-historique.md) : réutilisation du dépôt GitHub avec purge des blobs lourds de l'historique.
3. [ADR 0003](../../docs/adr/0003-wikidata-source-primaire.md) : Wikidata via QLever comme source primaire, Wikipedia pour les résumés, sync mensuelle Oban.
4. [ADR 0004](../../docs/adr/0004-frontieres-historiques-cliopatria.md) : Cliopatria comme socle de frontières historiques, historical-basemaps en complément.
5. [ADR 0005](../../docs/adr/0005-front-liveview-hooks-maplibre-d3.md) : carte MapLibre et frise d3 en hooks LiveView vanilla ; état via LiveView, volumes via endpoints JSON.
6. [ADR 0006](../../docs/adr/0006-modele-temporel-historical-date.md) : modèle temporel HistoricalDate (année astronomique signée plus précision).
7. [ADR 0007](../../docs/adr/0007-postgis-diffusion-geojson.md) : stockage PostGIS, diffusion GeoJSON bornée (bbox plus fenêtre plus importance).
8. [ADR 0008](../../docs/adr/0008-licence-agpl-principes-ethiques.md) : licence AGPL-3.0 et principes éthiques non négociables (zéro tracking, CSP stricte, attribution).
9. [ADR 0009](../../docs/adr/0009-surcouche-de-contributions.md) : surcouche de contributions résolue à l'écriture, jamais à la lecture (`overridden_fields`).

Le gabarit d'ADR est [`docs/adr/0000-template.md`](../../docs/adr/0000-template.md).
