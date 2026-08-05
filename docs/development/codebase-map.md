# Carte du code (où trouver quoi)

Cette carte répond à la question « je veux faire X, quels fichiers ouvrir ? ». Pour la vue conceptuelle (couches, contextes, flux), voir [architecture.md](architecture.md). Pour la procédure pas à pas, voir [adding-a-feature.md](adding-a-feature.md).

Repères rapides :

| Je veux... | J'ouvre en priorité |
|------------|---------------------|
| Ajouter un champ à l'événement | [`lib/amanogawa/atlas/event.ex`](../../lib/amanogawa/atlas/event.ex) + une migration dans [`priv/repo/migrations/`](../../priv/repo/migrations) + [`lib/amanogawa/atlas.ex`](../../lib/amanogawa/atlas.ex) |
| Ajouter un endpoint JSON | [`lib/amanogawa_web/router.ex`](../../lib/amanogawa_web/router.ex) + [`lib/amanogawa_web/controllers/api/`](../../lib/amanogawa_web/controllers/api) + un module dans [`lib/amanogawa_web/params/`](../../lib/amanogawa_web/params) |
| Modifier le rendu de la carte | [`assets/js/hooks/map_hook.js`](../../assets/js/hooks/map_hook.js) + [`assets/js/map/`](../../assets/js/map) |
| Modifier la frise | [`assets/js/hooks/timeline.js`](../../assets/js/hooks/timeline.js) + [`assets/js/lib/`](../../assets/js/lib) |
| Toucher à une requête PostGIS | [`lib/amanogawa/atlas/event_queries.ex`](../../lib/amanogawa/atlas/event_queries.ex) ou [`border_queries.ex`](../../lib/amanogawa/atlas/border_queries.ex) |
| Ajouter un champ corrigeable | [`lib/amanogawa/atlas/overridable_field.ex`](../../lib/amanogawa/atlas/overridable_field.ex) |
| Importer des frontières | mix tasks dans [`lib/mix/tasks/`](../../lib/mix/tasks) |

## Contexte Atlas (read model servi à l'UI)

Façade : [`Amanogawa.Atlas`](../../lib/amanogawa/atlas.ex). Schéma PG `atlas`.

### Façade et fonctions publiques principales

| Fonction | Rôle |
|----------|------|
| `list_events_geojson/1` | LA requête critique : événements dans (bbox, fenêtre, importance), GeoJSON borné |
| `event_histogram/1` | Comptes par bucket temporel pour l'histogramme de la frise |
| `list_borders_geojson/1` | Frontières actives à l'année donnée, GeoJSON |
| `get_event_summary/1` | Détail d'un événement pour le panneau (par QID) |
| `get_event_by_qid/1`, `list_events_by_qids/1`, `event_ids_by_qids/1` | Lookups par QID |
| `list_event_links_geojson/1` | Relations typées d'un événement (LineString par lien) |
| `upsert_events/1`, `upsert_event_links/1` | Écriture par l'ingestion (upsert par QID, préservation des `overridden_fields`) |
| `apply_field_override/3`, `release_field_override/3`, `create_contributed_event/1` | Seule porte d'entrée des contributions vers Atlas (ADR 0009) |
| `upsert_polity/1`, `replace_borders/3` | Écriture des données Cliopatria (remplacement transactionnel par source) |
| `list_events_to_enrich/1`, `put_event_summary/...`, `mark_summary_attempt/1` | Support de l'enrichissement Wikipedia |
| `count_events/0`, `count_event_links/0`, `count_borders/0`, `count_polities/0`, `last_border_import_at/0`, `count_boundary_year_overlaps/1` | Compteurs pour tests et métriques de sync |
| `format_axis_year/2..3`, `flatten_date/2` | Délégations d'affichage (vers `TimeScale.Format` et `Event`) |

### Modules internes

| Module | Responsabilité | Si tu veux... |
|--------|----------------|---------------|
| [`atlas/event.ex`](../../lib/amanogawa/atlas/event.ex) | Schéma Ecto `atlas.events` (labels fr/en, extract, dates plates, `geom Point`, `sitelink_count`, `overridden_fields`, `origin`) | ajouter ou modifier un champ d'événement |
| [`atlas/event_link.ex`](../../lib/amanogawa/atlas/event_link.ex) | Schéma `atlas.event_links` (arêtes typées `:part_of`, `:follows`, `:cause`, `:effect`, `:significant`) | changer les types de relations |
| [`atlas/polity.ex`](../../lib/amanogawa/atlas/polity.ex) | Schéma `atlas.polities` (entité politique Cliopatria) | toucher aux entités de frontières |
| [`atlas/border.ex`](../../lib/amanogawa/atlas/border.ex) | Schéma `atlas.borders` (`geom`, `geom_medium`, `geom_low` MultiPolygon, `from_year`/`to_year`, `area_km2`) | changer le modèle de frontières |
| [`atlas/event_queries.ex`](../../lib/amanogawa/atlas/event_queries.ex) | Toutes les requêtes PostGIS des événements (fragments `ST_Intersects`, `width_bucket`, ...) : `list_events/1`, `list_links/1`, `bucket_edges/1`, `histogram_counts/1` | écrire ou optimiser une requête d'événements |
| [`atlas/border_queries.ex`](../../lib/amanogawa/atlas/border_queries.ex) | Toutes les requêtes PostGIS des frontières : `list_active_borders/1`, `insert_batch/3`, `purge_source/1`, `purge_orphan_polities/1`, `last_import_at/0`, `count_boundary_year_overlaps/1` | écrire ou optimiser une requête de frontières |
| [`atlas/overridable_field.ex`](../../lib/amanogawa/atlas/overridable_field.ex) | Énumère les champs corrigeables (`:label_fr`, `:label_en`, `:begin_date`, `:end_date`, `:position`) et les traduit en attrs (`to_applied_attrs/2`, `to_released_attrs/2`) | ouvrir un nouveau champ à la contribution |
| [`atlas/time_scale.ex`](../../lib/amanogawa/atlas/time_scale.ex) | Échelle symlog partagée Elixir/JS (`position/2`, `year/2`, `ticks/3`, `default/0`) | changer l'échelle temporelle |
| [`atlas/time_scale/format.ex`](../../lib/amanogawa/atlas/time_scale/format.ex) | Formatage des années d'axe respectant la précision | changer l'affichage des graduations |
| [`atlas/polity_color.ex`](../../lib/amanogawa/atlas/polity_color.ex) | Couleur stable par nom de polity | changer la coloration des frontières |

Pattern à respecter : « PostGIS via des fragments dans un seul module de requête ». Ne pas disperser du SQL géo ailleurs que dans `EventQueries` / `BorderQueries`.

## Contexte Ingestion (pipelines d'import)

Façade : [`Amanogawa.Ingestion`](../../lib/amanogawa/ingestion.ex). Schéma PG `ingestion`.

### Façade et fonctions publiques principales

| Fonction | Rôle |
|----------|------|
| `start_events_import/1`, `resume_events_import/1` | Import des événements Wikidata |
| `start_links_import/1`, `resume_links_import/1` | Import des relations Wikidata |
| `start_summaries_enrichment/1` | Enrichissement des résumés Wikipedia |
| `await_run/2`, `get_sync_run/1`, `last_sync_run/1` | Suivi de l'état des runs |
| `import_cliopatria/2`, `import_historical_basemaps/2` | Import des frontières (délégations) |

### Modules internes

| Module | Responsabilité | Si tu veux... |
|--------|----------------|---------------|
| [`ingestion/sparql_client.ex`](../../lib/amanogawa/ingestion/sparql_client.ex) | Behaviour port SPARQL (`query/2`) + struct `Result` | changer le contrat SPARQL |
| [`ingestion/sparql_client/qlever.ex`](../../lib/amanogawa/ingestion/sparql_client/qlever.ex) | Adaptateur QLever (production) | changer l'endpoint SPARQL réel |
| [`ingestion/wikipedia_client.ex`](../../lib/amanogawa/ingestion/wikipedia_client.ex) | Behaviour port Wikipedia (`fetch_summary/2`) + struct `Summary` | changer le contrat résumés |
| [`ingestion/wikipedia_client/rest.ex`](../../lib/amanogawa/ingestion/wikipedia_client/rest.ex) | Adaptateur REST Wikipedia (User-Agent, cache, backoff) | changer l'appel Wikipedia réel |
| [`ingestion/wikidata/templates.ex`](../../lib/amanogawa/ingestion/wikidata/templates.ex) | Construction des requêtes SPARQL | modifier une requête d'extraction |
| [`ingestion/wikidata/blocklist.ex`](../../lib/amanogawa/ingestion/wikidata/blocklist.ex) | Classes parasites exclues de l'arbre Q1190554 | curer les résultats d'import |
| [`ingestion/wikidata/event_decoder.ex`](../../lib/amanogawa/ingestion/wikidata/event_decoder.ex) / [`link_decoder.ex`](../../lib/amanogawa/ingestion/wikidata/link_decoder.ex) | Décodage des lignes SPARQL en structs `ExtractedEvent` / `ExtractedLink` | changer le mapping Wikidata vers domaine |
| [`ingestion/wikidata/extracted_event.ex`](../../lib/amanogawa/ingestion/wikidata/extracted_event.ex) / [`extracted_link.ex`](../../lib/amanogawa/ingestion/wikidata/extracted_link.ex) | Structs intermédiaires | ajouter un attribut extrait |
| [`ingestion/workers/paged_import.ex`](../../lib/amanogawa/ingestion/workers/paged_import.ex) | Behaviour d'orchestration paginée partagé (`page_query/1`, `apply_page/3`, `fetched_count_key/0`) | changer la pagination des imports |
| [`ingestion/workers/import_events.ex`](../../lib/amanogawa/ingestion/workers/import_events.ex) / [`import_links.ex`](../../lib/amanogawa/ingestion/workers/import_links.ex) | Workers Oban d'import | changer un worker d'import |
| [`ingestion/workers/enrich_summaries.ex`](../../lib/amanogawa/ingestion/workers/enrich_summaries.ex) | Worker Oban d'enrichissement Wikipedia | changer l'enrichissement |
| [`ingestion/workers/scheduled_sync.ex`](../../lib/amanogawa/ingestion/workers/scheduled_sync.ex) | Point d'entrée Oban Cron mensuel | changer le calendrier de sync |
| [`ingestion/workers/run_guard.ex`](../../lib/amanogawa/ingestion/workers/run_guard.ex) | Garde de dernière ligne (capture d'exception) | changer la gestion d'échec des workers |
| [`ingestion/borders/geojson_stream.ex`](../../lib/amanogawa/ingestion/borders/geojson_stream.ex) | Scanner GeoJSON borné en mémoire | changer le streaming des frontières |
| [`ingestion/borders/feature_validation.ex`](../../lib/amanogawa/ingestion/borders/feature_validation.ex) / [`importer.ex`](../../lib/amanogawa/ingestion/borders/importer.ex) | Validation et import des features | changer l'import générique de frontières |
| [`ingestion/cliopatria/parser.ex`](../../lib/amanogawa/ingestion/cliopatria/parser.ex) / [`importer.ex`](../../lib/amanogawa/ingestion/cliopatria/importer.ex) | Parsing et import Cliopatria (lignes `Type=POLITY` seulement) | changer l'import Cliopatria |
| [`ingestion/historical_basemaps/parser.ex`](../../lib/amanogawa/ingestion/historical_basemaps/parser.ex) / [`importer.ex`](../../lib/amanogawa/ingestion/historical_basemaps/importer.ex) | Parsing et import historical-basemaps | changer l'import historical-basemaps |
| [`ingestion/sync_run.ex`](../../lib/amanogawa/ingestion/sync_run.ex) | Schéma `ingestion.sync_runs` (état d'un run) | changer l'état de suivi des imports |

## Contexte Accounts (authentification)

Façade : [`Amanogawa.Accounts`](../../lib/amanogawa/accounts.ex). Schéma PG `accounts`.

### Façade et fonctions publiques principales

| Fonction | Rôle |
|----------|------|
| `generate_magic_link_token/1`, `redeem_magic_link_token/1`, `deliver_magic_link/4` | Cycle du magic link |
| `create_session_token/1`, `get_user_by_session_token/1`, `get_user_and_session_token/1`, `renew_session_token/1`, `delete_session_token/1`, `current_session_token?/2` | Sessions révocables |
| `list_session_tokens/1`, `revoke_session_token/2` | Gestion des sessions actives (page `/compte`) |
| `get_user!/1`, `get_user_by_email/1`, `normalize_email/1`, `set_display_name/2`, `display_names_by_ids/1` | Lookups et profil |
| `reviewer?/1` | Test du rôle relecteur |
| `export_user_data/1`, `delete_user/1`, `purge_expired_tokens/0` | RGPD et hygiène des tokens |

### Modules internes

| Module | Responsabilité |
|--------|----------------|
| [`accounts/user.ex`](../../lib/amanogawa/accounts/user.ex) | Schéma `accounts.users` (email, `role`, `display_name`) |
| [`accounts/magic_link_token.ex`](../../lib/amanogawa/accounts/magic_link_token.ex) | Schéma `accounts.magic_link_tokens` |
| [`accounts/session_token.ex`](../../lib/amanogawa/accounts/session_token.ex) | Schéma `accounts.session_tokens` |
| [`accounts/magic_link.ex`](../../lib/amanogawa/accounts/magic_link.ex) | Logique de génération et validation du magic link |
| [`accounts/session.ex`](../../lib/amanogawa/accounts/session.ex) | Logique de session (create, get_user, renew, revoke, list_active) |
| [`accounts/scope.ex`](../../lib/amanogawa/accounts/scope.ex) | `@current_scope` : contexte de sécurité de chaque requête |
| [`accounts/magic_link_notifier.ex`](../../lib/amanogawa/accounts/magic_link_notifier.ex) + [`/mailer.ex`](../../lib/amanogawa/accounts/magic_link_notifier/mailer.ex) | Behaviour + adaptateur d'envoi du mail |
| [`accounts/magic_link_throttle.ex`](../../lib/amanogawa/accounts/magic_link_throttle.ex) | Throttle des demandes de lien |
| [`accounts/workers/purge_expired_tokens.ex`](../../lib/amanogawa/accounts/workers/purge_expired_tokens.ex) | Worker Oban de purge des tokens expirés |

## Contexte Contributions (édition collaborative)

Façade : [`Amanogawa.Contributions`](../../lib/amanogawa/contributions.ex). Schéma PG `contributions`.

### Façade et fonctions publiques principales

| Fonction | Rôle |
|----------|------|
| `propose/2`, `propose/3` | Soumettre une proposition (correction ou nouvel événement) |
| `accept_override/3`, `reject_override/3` | Décision d'un relecteur (appelle Atlas à l'acceptation) |
| `appeal_override/3`, `review_appeal/3` | Appel d'un rejet et sa relecture |
| `list_review_queue/1`, `list_overrides/1`, `get_override/1`, `count_by_status/0` | File de relecture et statistiques |
| `list_revisions/1`, `list_revisions_by_override_ids/1` | Historique append-only d'un override |
| `record_sync_divergences/1`, `list_open_conflicts/1`, `resolve_conflict/3` | Conflits de synchronisation |
| `list_public/1`, `event_contribution_summary/1`, `public_stats/0` | Feed public de transparence |
| `export_user_contributions/1`, `anonymize_user/1` | RGPD (portabilité, anonymisation plutôt que suppression) |

### Modules internes

| Module | Responsabilité |
|--------|----------------|
| [`contributions/override.ex`](../../lib/amanogawa/contributions/override.ex) | Schéma `contributions.overrides` (une ligne par champ corrigé, `status`, `wikidata_value_at_acceptance`) |
| [`contributions/revision.ex`](../../lib/amanogawa/contributions/revision.ex) | Schéma `contributions.revisions` (historique append-only) |
| [`contributions/conflict.ex`](../../lib/amanogawa/contributions/conflict.ex) | Schéma `contributions.conflicts` (divergences de sync) |
| [`contributions/proposal_throttle.ex`](../../lib/amanogawa/contributions/proposal_throttle.ex) | Throttle des propositions |
| [`contributions/decision_notifier.ex`](../../lib/amanogawa/contributions/decision_notifier.ex) + [`/email.ex`](../../lib/amanogawa/contributions/decision_notifier/email.ex) | Behaviour + adaptateur de notification de décision |

## Shared kernel (hors contextes)

| Module | Responsabilité | Si tu veux... |
|--------|----------------|---------------|
| [`historical_date.ex`](../../lib/amanogawa/historical_date.ex) | Embedded schema HistoricalDate (`year` signé, `precision` 0-11, `calendar`) : `new/1`, `new!/1`, `sort_key/1`, `compare/2`, `min_year/0`, `max_year/0` | manipuler des dates historiques |
| [`historical_date/wikidata.ex`](../../lib/amanogawa/historical_date/wikidata.ex) | Décodage et normalisation des dates Wikidata (décalage RDF, faux 1er janvier) | corriger un cas de date Wikidata |
| [`historical_date/formatter.ex`](../../lib/amanogawa/historical_date/formatter.ex) | Affichage respectant la précision | changer l'affichage d'une date |
| [`wikimedia_url.ex`](../../lib/amanogawa/wikimedia_url.ex) | Construction et validation des URL Wikimedia | toucher aux liens vers Wikipedia/Wikidata |

## Couche web

### Routeur et endpoint

| Fichier | Contenu |
|---------|---------|
| [`router.ex`](../../lib/amanogawa_web/router.ex) | Pipelines (`:browser`, `:static_page`, `:api`, `:health`, `:authenticated`, `:reviewer`), live_sessions (`:current_user`, `:require_authenticated_user`, `:require_reviewer`), routes JSON `/api/*` |
| [`endpoint.ex`](../../lib/amanogawa_web/endpoint.ex) | Point d'entrée Plug/Phoenix |
| [`user_auth.ex`](../../lib/amanogawa_web/user_auth.ex) | Plomberie de session : `fetch_current_scope_for_user`, `require_authenticated_user`, `require_reviewer`, hooks `on_mount` |

### LiveViews (état applicatif via WebSocket)

| Module | Route | Rôle |
|--------|-------|------|
| [`live/explore_live.ex`](../../lib/amanogawa_web/live/explore_live.ex) | `/` | Carte plein écran + frise : `handle_params/3` parse l'URL et `push_event` vers les hooks ; `handle_event` traite `select_event`, `map_moved`, `select_time_window`, `position_picked` ; `push_patch` l'URL |
| [`live/login_live.ex`](../../lib/amanogawa_web/live/login_live.ex) | `/connexion` | Formulaire email unique du magic link |
| [`live/account_live.ex`](../../lib/amanogawa_web/live/account_live.ex) | `/compte` | Page compte (sessions actives, nom d'affichage) |
| [`live/review_queue_live.ex`](../../lib/amanogawa_web/live/review_queue_live.ex) | `/relecture` | File de relecture (coeur de la modération V1) |
| [`live/conflicts_live.ex`](../../lib/amanogawa_web/live/conflicts_live.ex) | `/relecture/conflits` | Conflits de synchronisation à arbitrer |
| [`live/contributions_live.ex`](../../lib/amanogawa_web/live/contributions_live.ex) | `/contributions` | Feed public chronologique |
| [`live/contribution_live.ex`](../../lib/amanogawa_web/live/contribution_live.ex) | `/contributions/:id` | Détail public d'une contribution (formulaire d'appel pour l'auteur) |
| [`live/proposal_form_component.ex`](../../lib/amanogawa_web/live/proposal_form_component.ex) | (LiveComponent) | Formulaire de proposition (correction ou nouvel événement), isolé dans ExploreLive |

### Controllers

| Module | Routes | Rôle |
|--------|--------|------|
| [`controllers/api/event_controller.ex`](../../lib/amanogawa_web/controllers/api/event_controller.ex) | `GET /api/events`, `/events/histogram`, `/events/:qid/summary`, `/events/:qid/links` | Endpoints JSON read-only des événements (module `AmanogawaWeb.Controllers.Api.EventController`) |
| [`controllers/api/border_controller.ex`](../../lib/amanogawa_web/controllers/api/border_controller.ex) | `GET /api/borders` | Endpoint JSON read-only des frontières |
| [`controllers/page_controller.ex`](../../lib/amanogawa_web/controllers/page_controller.ex) | `/sources`, `/mentions-legales`, `/confidentialite`, `/moderation` | Pages statiques sessionless (`sources/2`, `legal/2`, `privacy/2`, `moderation/2`) |
| [`controllers/session_controller.ex`](../../lib/amanogawa_web/controllers/session_controller.ex) | `/connexion/:token`, `/deconnexion` | `confirm/2`, `create/2`, `delete/2` du magic link |
| [`controllers/account_controller.ex`](../../lib/amanogawa_web/controllers/account_controller.ex) | `GET /compte/export` | `export/2` : export RGPD |
| [`controllers/proposal_controller.ex`](../../lib/amanogawa_web/controllers/proposal_controller.ex) | `GET /proposer` | `new/2` : point d'entrée visiteur anonyme des propositions |
| [`controllers/health_controller.ex`](../../lib/amanogawa_web/controllers/health_controller.ex) | `GET /health` | `check/2` : sonde de liveness |

### Params (validation et bornage stricts)

Tout paramètre d'entrée d'un endpoint passe par un de ces modules. Ils bornent côté serveur (aucune valeur n'est reçue non validée).

| Module | Rôle |
|--------|------|
| [`params/events_query.ex`](../../lib/amanogawa_web/params/events_query.ex) | Valide `bbox`, `from`, `to`, `limit` de `GET /api/events` (`parse/1`, `parse_bbox/1`) |
| [`params/histogram_query.ex`](../../lib/amanogawa_web/params/histogram_query.ex) | Valide les params de l'histogramme |
| [`params/border_query.ex`](../../lib/amanogawa_web/params/border_query.ex) | Valide `year` de `GET /api/borders` |
| [`params/event_id.ex`](../../lib/amanogawa_web/params/event_id.ex) | Valide un identifiant d'événement (`valid?/1`, format QID) |
| [`params/explore_params.ex`](../../lib/amanogawa_web/params/explore_params.ex) | Parse et borne l'état d'exploration depuis l'URL de `/` (`parse/1`, `to_query/1`, `valid_view?/3`, `valid_window?/2`) |

### Plugs de sécurité et helpers

| Module | Rôle |
|--------|------|
| [`plugs/content_security_policy.ex`](../../lib/amanogawa_web/plugs/content_security_policy.ex) | CSP stricte sur les requêtes navigateur |
| [`plugs/rate_limit.ex`](../../lib/amanogawa_web/plugs/rate_limit.ex) | Rate limit par IP sur le pipeline `:api` |
| [`plugs/set_locale.ex`](../../lib/amanogawa_web/plugs/set_locale.ex) | Résolution de la locale (fr/en) |
| [`rate_limit.ex`](../../lib/amanogawa_web/rate_limit.ex) | Mécanisme sous-jacent (Hammer, ETS, fenêtre fixe) |
| [`client_ip.ex`](../../lib/amanogawa_web/client_ip.ex) | Résolution de l'IP réelle d'un socket LiveView |
| [`contributions/attribution.ex`](../../lib/amanogawa_web/contributions/attribution.ex) | Attribution publique partagée des pages de transparence |

### Composants réutilisables

| Module | Rôle |
|--------|------|
| [`components/event_panel.ex`](../../lib/amanogawa_web/components/event_panel.ex) | Panneau de détail d'un événement (`event_panel/1`, attrs `event`, `current_scope`, `contribution_summary`, `view_query`) |
| [`components/time_legend.ex`](../../lib/amanogawa_web/components/time_legend.ex) | Légende du gradient temporel |
| [`components/core_components.ex`](../../lib/amanogawa_web/components/core_components.ex) | Composants de base Phoenix |
| [`components/layouts.ex`](../../lib/amanogawa_web/components/layouts.ex) + [`layouts/root.html.heex`](../../lib/amanogawa_web/components/layouts/root.html.heex) | Layouts |

## Front (assets/js)

Enregistrement des hooks : [`assets/js/app.js`](../../assets/js/app.js) (`MapHook`, `TimelineHook`).

### Hooks et contrat d'événements

| Hook | Fichier | Rôle |
|------|---------|------|
| `MapHook` | [`hooks/map_hook.js`](../../assets/js/hooks/map_hook.js) | Carte MapLibre : fetch `GET /api/events` et `/api/borders`, style par expressions, picking de position |
| `TimelineHook` | [`hooks/timeline.js`](../../assets/js/hooks/timeline.js) | Frise d3 symlog, histogramme, drag de la fenêtre temporelle |

Contrat d'événements LiveView (WebSocket) :

| Événement | Sens | Émis / reçu par |
|-----------|------|-----------------|
| `set_time_window` `{from, to}` | serveur vers hooks | reçu par MapHook et TimelineHook |
| `select_time_window` `{from, to}` | hook vers serveur | poussé par TimelineHook (debounce 150 ms) |
| `set_view` `{z, lat, lng}` | serveur vers hook | reçu par MapHook |
| `map_moved` `{z, lat, lng}` | hook vers serveur | poussé par MapHook |
| `select_event` `{qid}` / `deselect_event` | hook vers serveur | poussé par MapHook |
| `event_selected` `{qid}` / `event_deselected` | serveur vers hook | reçu par MapHook |
| `enable_position_picking` / `disable_position_picking` | serveur vers hook | reçu par MapHook (mode proposition) |
| `position_picked` `{lng, lat}` | hook vers serveur | poussé par MapHook |

Événement DOM inter-hooks (même onglet, sans round-trip serveur) : `amanogawa:time-window-preview` (constante `TIME_WINDOW_PREVIEW_EVENT`), diffusé par TimelineHook pendant le drag, consommé par MapHook pour recolorer immédiatement.

### Modules purs (testés sous node:test)

| Répertoire / fichier | Rôle |
|----------------------|------|
| [`lib/time_scale.js`](../../assets/js/lib/time_scale.js) | Échelle symlog (jumeau JS de `Amanogawa.Atlas.TimeScale`, même fixture d'ancres) |
| [`lib/time_gradient.js`](../../assets/js/lib/time_gradient.js) | Interpolation du gradient temporel, définition de `TIME_WINDOW_PREVIEW_EVENT` |
| [`lib/time_window.js`](../../assets/js/lib/time_window.js) | Logique de la fenêtre temporelle (clamp, resize, pan) |
| [`lib/time_format.js`](../../assets/js/lib/time_format.js) | Formatage des années côté client |
| [`lib/window_echo.js`](../../assets/js/lib/window_echo.js) | Garde anti-écho des fenêtres poussées |
| [`map/event_layers.js`](../../assets/js/map/event_layers.js) | Expressions de style des marqueurs d'événements |
| [`map/border_layers.js`](../../assets/js/map/border_layers.js) | Couches de frontières semi-transparentes |
| [`map/link_layers.js`](../../assets/js/map/link_layers.js) | Couches de relations (LineString par lien) |
| [`map/bbox.js`](../../assets/js/map/bbox.js) | Sérialisation de la bbox attendue par `/api/events` |
| [`map/style_utils.js`](../../assets/js/map/style_utils.js) | Fabrique de FeatureCollection vide, transitions de paint |
| [`map/hover_card.js`](../../assets/js/map/hover_card.js) | Carte de survol (titre, extrait tronqué, vignette, attribution CC BY-SA) |
| [`map/debounce.js`](../../assets/js/map/debounce.js), [`map/truncate.js`](../../assets/js/map/truncate.js) | Utilitaires |

## Migrations, mix tasks et tests

### Migrations

[`priv/repo/migrations/`](../../priv/repo/migrations). Points de repère : `20260723090000_create_postgis_and_schemas.exs` (PostGIS + 4 schémas PG), `..._create_atlas_events.exs`, `..._create_atlas_event_links.exs`, `..._add_events_query_indexes.exs` (index `(begin_year)` + GiST `geom`), `..._create_atlas_polities_and_borders.exs`, `..._create_accounts_schema_and_tables.exs`, `..._create_contributions_schema_and_tables.exs`, `..._add_overrides_columns_to_atlas_events.exs` (colonne `overridden_fields`), `..._add_role_and_display_name_to_accounts_users.exs`.

### Mix tasks

| Task | Fichier | Rôle |
|------|---------|------|
| `mix amanogawa.sync` | [`lib/mix/tasks/amanogawa.sync.ex`](../../lib/mix/tasks/amanogawa.sync.ex) | Lancer une synchronisation |
| `mix amanogawa.import.cliopatria` | [`lib/mix/tasks/amanogawa.import.cliopatria.ex`](../../lib/mix/tasks/amanogawa.import.cliopatria.ex) | Importer les frontières Cliopatria |
| `mix amanogawa.import.historical_basemaps` | [`lib/mix/tasks/amanogawa.import.historical_basemaps.ex`](../../lib/mix/tasks/amanogawa.import.historical_basemaps.ex) | Importer historical-basemaps |

### Tests (structure miroir)

[`test/`](../../test) reflète la structure de `lib/`. Points de repère :

- `test/amanogawa/<contexte>/` : tests unitaires du domaine (contexte par contexte).
- `test/amanogawa_web/` : `live/`, `controllers/`, `controllers/api/`, `params/`, `plugs/`, `components/`.
- `test/e2e/` : parcours de bout en bout (Wallaby).
- `test/mix/tasks/` : tests des mix tasks.
- `test/support/` : `FeatureCase`, `E2EHelpers`, générateurs StreamData (`generators/`), et fixtures (`fixtures/` : `sparql/`, `wikipedia/`, `cliopatria/`, `historical_basemaps/`, `time_scale/anchors.json`).
- Côté JS : les tests `*.test.js` vivent à côté des modules (`assets/js/map/`, `assets/js/test/`), exécutés sous `node:test`.

Pour la stratégie de test détaillée (Mox, StreamData, FeatureCase, fixture d'ancres partagée), voir [testing.md](testing.md).
