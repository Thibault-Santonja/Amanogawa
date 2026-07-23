# Synchronisation Wikidata/Wikipedia

Date : 2026-07-23
Version : 1.0

Guide d'exploitation de la synchronisation du corpus (événements, relations, résumés) décrite par l'ADR 0003 et l'issue #013 (feature 002). Public visé : l'opérateur qui lance le premier import en production, ou tout contributeur self-host qui reprend une synchronisation en échec.

## Prérequis

- Application démarrée avec accès à la base PostgreSQL (extension PostGIS) et à Internet (endpoint QLever et API REST Wikipedia).
- Migrations appliquées (`mix ecto.migrate` en développement, migrations automatiques au déploiement).
- Aucune autre synchronisation du même type (`events`, `links` ou `summaries`) déjà en cours : la façade `Amanogawa.Ingestion` refuse de démarrer un second run concurrent de même nature.
- Étiquette Wikimedia respectée (`.claude/rules/ethics.md`) : ne jamais paralléliser les imports, ne jamais réduire les délais entre lots configurés dans `config/config.exs`.

## Premier import en production

Le premier import passe par la mix task, jamais par la planification automatique (le cron ne fait que rafraîchir un corpus déjà initialisé, voir plus bas). Lancer les trois étapes dans l'ordre, chacune attendant la clôture de la précédente avant de continuer :

```
mix amanogawa.sync events
mix amanogawa.sync links
mix amanogawa.sync summaries
```

Ou de façon équivalente, enchaînées automatiquement (la task s'arrête proprement dès qu'une étape échoue, sans lancer la suivante) :

```
mix amanogawa.sync all
```

Chaque étape bloque le terminal jusqu'à sa clôture et affiche une ligne de progression périodique (compteurs, position dans la pagination), puis un résumé final (durée, compteurs, statut). Lancer la commande dans `tmux`, `screen`, ou avec `nohup` pour un import long qui ne doit pas s'interrompre si la session SSH se coupe.

### Volumétrie et durées attendues

| Étape | Volume attendu | Durée indicative |
|-------|-----------------|-------------------|
| `events` | environ 420 000 événements géolocalisables (P625 direct ou P276 -> P625) | de l'ordre de la dizaine de minutes (pagination QLever, quelques secondes par page) |
| `links` | relations P361, P155/P156, P793, P1344 entre événements déjà importés | du même ordre de grandeur que `events` |
| `summaries` | environ 17 000 résumés en français et 29 000 en anglais (repli fr -> en) | plusieurs heures : lots lents et espacés (`inter_batch_delay_seconds`, 30 secondes par défaut) pour respecter l'étiquette Wikimedia |

Ces chiffres proviennent de l'étude `docs/studies/2026-07-sources-donnees-historiques.md` citée par l'ADR 0003 ; ils évoluent avec le contenu de Wikidata et ne sont pas des garanties strictes.

### Vérifier avant d'écrire : `--dry-run`

Chaque cible accepte `--dry-run` : la chaîne complète s'exécute (requête, décodage, comptage) mais aucune écriture n'a lieu dans `Amanogawa.Atlas`. Utile pour valider une évolution de la liste noire de classes ou du décodage avant un import réel.

```
mix amanogawa.sync events --dry-run
```

### Borner un import : `--limit`

`--limit N` plafonne le nombre d'éléments traités par l'étape (événements, relations ou résumés selon la cible). Pratique pour un test rapide sur poste de développement :

```
mix amanogawa.sync events --limit 100 --dry-run
```

`--limit 0` démarre puis clôture immédiatement un run vide (aucune requête envoyée) : utile pour vérifier que la commande s'exécute sans lancer de véritable import.

## Suivi d'une synchronisation

Toute exécution, manuelle ou planifiée, laisse une trace dans `ingestion.sync_runs` : statut, compteurs cumulés, curseur de reprise, horodatages, dernière erreur. Depuis `psql` ou tout client SQL :

```sql
-- Dernier run de chaque type
select kind, status, started_at, finished_at, counts, last_error
from ingestion.sync_runs
order by started_at desc
limit 10;

-- Runs en cours
select id, kind, started_at, counts
from ingestion.sync_runs
where status = 'running';

-- Runs en échec, du plus récent au plus ancien
select id, kind, started_at, finished_at, last_error
from ingestion.sync_runs
where status = 'failed'
order by started_at desc;
```

Depuis `iex -S mix`, la façade offre les mêmes informations sans SQL direct :

```elixir
Amanogawa.Ingestion.last_sync_run(:events)
Amanogawa.Ingestion.get_sync_run("<uuid>")
```

## Reprise après échec

Un run `failed` n'est jamais repris automatiquement. Le message affiché par la mix task en cas d'échec contient la commande de reprise exacte (identifiant du run inclus).

- `events` et `links` conservent un curseur de pagination explicite (position dans l'espace des QID) : la reprise continue exactement où le run interrompu s'est arrêté, sans retraiter ce qui a déjà été importé.

  ```elixir
  sync_run = Amanogawa.Ingestion.get_sync_run("<uuid>")
  Amanogawa.Ingestion.resume_events_import(sync_run)
  # ou, pour les relations :
  Amanogawa.Ingestion.resume_links_import(sync_run)
  ```

- `summaries` n'a pas de fonction de reprise dédiée : sa sélection d'événements à enrichir exclut naturellement ceux déjà traités (curseur implicite). Relancer simplement la même commande reprend là où elle s'était arrêtée :

  ```
  mix amanogawa.sync summaries
  ```

## Planification automatique (Oban Cron)

Une fois le premier import terminé, la synchronisation mensuelle est automatique : `config/config.exs` déclare trois entrées `Oban.Plugins.Cron`, en heures creuses UTC, chacune espacée d'un jour pour laisser le temps à l'étape précédente de finir :

| Horaire (UTC) | Cible | Pourquoi ce décalage |
|----------------|-------|------------------------|
| `0 2 1 * *` (le 1er, 02h00) | `events` | premier maillon, rien n'en dépend |
| `0 2 2 * *` (le 2, 02h00) | `links` | a besoin des événements du jour précédent |
| `0 2 3 * *` (le 3, 02h00) | `summaries` | le cache de 30 jours (`summary_max_age_days`) limite un run mensuel à rafraîchir seulement les extraits expirés |

Chaque entrée cible `Amanogawa.Ingestion.Workers.ScheduledSync`, un worker de quelques lignes qui ne fait qu'appeler la façade `Amanogawa.Ingestion` (le même chemin de code que la mix task) : aucune orchestration n'est dupliquée entre le cron et l'exécution manuelle. Si un tick de cron tombe alors qu'un run du même type est encore en cours (import précédent anormalement long), il est ignoré silencieusement : pas de nouvelle ligne dans `ingestion.sync_runs` pour ce mois, visible en surveillant la table plutôt que par une alerte.

Modifier la planification : éditer les expressions cron dans `config/config.exs` (`config :amanogawa, Oban` bloc `plugins`), puis redéployer. Le plugin Cron est désactivé en environnement de test (`config/test.exs`, `plugins: false`) pour qu'aucune suite de tests ne déclenche de synchronisation.

## Étiquette Wikimedia

Rappel des règles non négociables (`.claude/rules/ethics.md`, ADR 0003) :

- Un seul import à la fois par type de pipeline (imposé par la façade et par la concurrence des queues Oban `:ingestion` et `:wikipedia`, toutes deux à 1).
- Ne jamais réduire `inter_batch_delay_seconds` (résumés) ni lancer plusieurs synchronisations en parallèle pour aller plus vite.
- User-Agent identifié sur chaque requête, cache agressif (résumés jamais rafraîchis avant `summary_max_age_days`, 30 jours par défaut).
- Préférer QLever pour les extractions massives ; WDQS reste réservé aux requêtes ponctuelles et fraîches.

## Dépannage

### `rate_limited`

L'API REST Wikipedia a répondu qu'il fallait ralentir. Le worker de résumés (`Amanogawa.Ingestion.Workers.EnrichSummaries`) gère ce cas nativement : il arrête le lot en cours et reprogramme le job après un délai (`retry_after` renvoyé par l'API, ou une valeur par défaut). Aucune intervention manuelle n'est nécessaire ; si la situation persiste sur plusieurs lots, vérifier qu'aucune autre source (autre déploiement, script externe) n'appelle la même API avec le même User-Agent.

### Endpoint indisponible (QLever ou Wikipedia)

Une erreur réseau (timeout, connexion refusée) fait échouer la page ou le lot en cours ; le worker retente automatiquement (jusqu'à 5 tentatives). Si l'endpoint reste indisponible au-delà des tentatives, le run se clôture `failed` avec `last_error` renseigné : vérifier l'état du service concerné (statut QLever, statut Wikipedia), puis reprendre avec la commande affichée par la mix task ou documentée ci-dessus une fois le service rétabli.

### Un run reste `running` indéfiniment

Un run ne devrait jamais rester `running` sans qu'un job Oban lui soit associé : vérifier la table `oban_jobs` (ou l'historique Oban) pour confirmer qu'un job existe bien pour ce `sync_run_id`. Si aucun job n'existe (cas anormal, par exemple après un arrêt brutal du nœud pendant l'insertion), clôturer manuellement le run en base (`status = 'failed'`, `last_error` renseigné) avant de le reprendre.
