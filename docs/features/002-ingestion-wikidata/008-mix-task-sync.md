# Issue #013 -- Mix task de synchronisation et planification Oban Cron

**Feature :** F02 -- Ingestion Wikidata / Wikipedia
**Priorité :** Haute
**Estimation :** 6h
**Prérequis :** #010, #011, #012

---

## Contexte

Les trois pipelines existent (événements #010, relations #011, résumés #012) et sont pilotables par la façade `Amanogawa.Ingestion`. Il manque les deux points d'entrée opérateur :

1. Une mix task `mix amanogawa.sync` pour l'import initial et les opérations manuelles (recharge après évolution de la blocklist, test en `--dry-run`, import partiel en `--limit` sur un poste de dev).
2. La planification récurrente : l'ADR 0003 prescrit une synchronisation mensuelle. Oban Cron enchaîne les trois étapes dans le bon ordre (les relations ont besoin des événements, les résumés aussi), en heures creuses, conformément à l'étiquette Wikimedia.

S'y ajoute la documentation d'exploitation `docs/ops/sync.md` : c'est elle qui permet à un opérateur (ou au futur contributeur self-host) de lancer, surveiller et reprendre une synchronisation sans lire le code.

La mix task ne réimplémente rien : elle valide les arguments, démarre l'application, appelle la façade et affiche la progression depuis les `SyncRun`. Même chemin de code que le cron, donc mêmes garanties (traçage, idempotence, reprise).

## User Story

> En tant qu'opérateur, je veux lancer `mix amanogawa.sync all` et laisser ensuite la synchronisation mensuelle tourner seule, afin de maintenir le corpus à jour sans intervention manuelle ni risque d'incohérence.

---

## Tâches

- [ ] Mix task `Mix.Tasks.Amanogawa.Sync` (`lib/mix/tasks/amanogawa.sync.ex`) :
  - argument cible obligatoire : `events` | `links` | `summaries` | `all` ; `all` enchaîne events puis links puis summaries, chaque étape attendant la clôture (`completed`) de la précédente et s'arrêtant proprement si elle finit en `failed` ;
  - options : `--limit N` (borne le nombre d'éléments traités, transmise à la façade) et `--dry-run` (toute la chaîne sauf les écritures, compteurs affichés en fin de run) ;
  - validation stricte des arguments avec message d'usage clair et code de sortie non nul en cas d'erreur (cible inconnue, limite non entière, option inconnue) ;
  - affichage de progression : suivi périodique du `SyncRun` courant (compteurs, tranche en cours), résumé final (durée, compteurs, statut) ; en cas d'échec, afficher `last_error` et la commande de reprise ;
  - `@shortdoc` et `@moduledoc` complets (c'est la doc de `mix help amanogawa.sync`).
- [ ] Exposer dans la façade `Amanogawa.Ingestion` ce qui manque au pilotage synchrone : `await_run/2` (attente de clôture d'un run avec timeout, par polling raisonnable du `SyncRun`, utilisable hors tests) ou équivalent par `Oban.drain_queue/1` en environnement de tâche ; choisir et documenter l'approche.
- [ ] Planification Oban Cron (config `config/config.exs`, plugin `Oban.Plugins.Cron`), synchronisation mensuelle en heures creuses (UTC) :
  - `0 2 1 * *` : `Workers.ImportEvents` (1er du mois, 02:00) ;
  - `0 2 2 * *` : `Workers.ImportLinks` (le lendemain, laissant à l'import des événements le temps de finir) ;
  - `0 2 3 * *` : `Workers.EnrichSummaries` (le surlendemain ; le cache de 30 jours fait qu'un run mensuel ne rafraîchit que l'expiré) ;
  - les workers refusant les runs concurrents (#010), un chevauchement éventuel échoue proprement et se voit dans `sync_runs`.
- [ ] Rédiger `docs/ops/sync.md` (français, conventions docs du projet) : prérequis, import initial pas à pas (`events` puis `links` puis `summaries`, durées et volumétries attendues : ~420 000 événements, ~17k/29k résumés fr/en), vérification en `--dry-run`, suivi via la table `ingestion.sync_runs` (requêtes SQL d'exemple), reprise après échec (`resume_*`), planification cron et comment la modifier, rappel de l'étiquette Wikimedia (ne pas paralléliser les imports, ne pas réduire les délais), dépannage des erreurs courantes (`rate_limited`, endpoint indisponible).
- [ ] Vérifier la config test : le plugin Cron ne doit jamais planifier de jobs en environnement de test (`plugins: false` ou config test dédiée).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : parsing des arguments (`events`, `all`, `--limit 100`, `--dry-run`) vers les options de façade attendues.
- [ ] **Edge case** : `--limit 0` (rien à faire, sortie propre) ; `all` avec une étape échouée s'arrête avant les suivantes.
- [ ] **Error case** : cible inconnue, `--limit abc`, option inconnue -> message d'usage et sortie en erreur (`Mix.raise` ou code de sortie non nul, à uniformiser).
- [ ] **Limit case** : cible `all` en `--dry-run` traverse les trois étapes sans aucune écriture.

### Property-based tests (si applicable)

- [ ] **Property** : non applicable.

### Doctests (si applicable)

- [ ] **Doctest** : non applicable (mix task) ; le `@moduledoc` tient lieu de documentation d'usage.

### Tests d'intégration

- [ ] **Intégration (DataCase + Mox + Oban.Testing)** : `Mix.Task.rerun("amanogawa.sync", ["events", "--limit", "10"])` avec `SparqlClientMock` sur fixtures -> événements en base, `SyncRun` `completed`, sortie contenant le résumé.
- [ ] **Intégration (dry-run)** : `amanogawa.sync all --dry-run` -> aucune ligne écrite dans `atlas.events`, `atlas.event_links`, ni d'extrait, mais compteurs non nuls affichés.
- [ ] **Intégration (ordre)** : `amanogawa.sync all` sur base vide avec fixtures -> les trois runs apparaissent dans `sync_runs` dans l'ordre events, links, summaries, chacun démarré après la clôture du précédent.
- [ ] **Intégration (config cron)** : la config Oban de prod contient les trois entrées cron attendues et la config test n'en planifie aucune (assertion sur la config, pas d'attente réelle).

### Tests end-to-end (si applicable)

- [ ] **E2E** : le parcours `mix amanogawa.sync all` sur fixtures constitue le test de bout en bout du pipeline F02 (couvert par les tests d'intégration ci-dessus, sans réseau).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/mix/tasks/amanogawa.sync.ex`
  - `lib/amanogawa/ingestion.ex` (attente de clôture de run)
  - `config/config.exs` (plugin Cron), `config/test.exs`
  - `docs/ops/sync.md`
  - `test/mix/tasks/amanogawa.sync_test.exs`
- **Documentation de référence** : ADR 0003 (sync mensuelle), `.claude/rules/ethics.md` (heures creuses, rythme), #010/#011/#012 (contrats de façade), documentation Oban (Cron plugin, drain_queue), `Mix.Task` (docs Elixir).
- **Compétences requises** : mix tasks (démarrage d'application, OptionParser), Oban Cron, rédaction de documentation d'exploitation.
- **Points d'attention** :
  - La mix task démarre l'application (`Mix.Task.run("app.start")`) : attention à la config Oban en contexte task (queues actives nécessaires pour un run réel ; en test, passer par les helpers Oban.Testing).
  - Ne pas dupliquer la logique d'orchestration dans la task : tout passe par la façade, la task n'est qu'une interface ligne de commande.
  - L'espacement d'un jour entre les étapes cron est un choix simple et robuste ; un chaînage événementiel (job suivant inséré à la clôture du précédent) est une amélioration possible, à documenter comme telle et non à implémenter ici.
  - `docs/ops/sync.md` suit les conventions docs du projet : français accentué, pas d'emoji, pas de tirets cadratins, 3 niveaux de titres max.
  - Penser au premier import en production : il passe par la mix task (pas par le cron), et `docs/ops/sync.md` doit le dire explicitement.
