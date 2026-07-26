# Issue #035 -- Coexistence avec la sync mensuelle et examen des divergences

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 10h
**Prérequis :** #034

---

## Contexte

Le contexte Contributions (#034) sait appliquer un override accepté dans `atlas.events`. Reste l'autre moitié du principe des données en couches : la sync mensuelle Wikidata (`Amanogawa.Ingestion.Workers.ImportEvents`, cron Oban via `ScheduledSync`, ADR 0003) ne doit JAMAIS écraser un champ sous override accepté, et symétriquement un override ne doit jamais masquer silencieusement une évolution de Wikidata : chaque divergence est journalisée dans `contributions.conflicts` et examinée par un relecteur. C'est l'issue qui rend le principe vérifiable par des tests d'intégration, pas seulement affirmé.

Aujourd'hui, `Amanogawa.Atlas.upsert_events/1` remplace en bloc les colonnes de `@wikidata_columns` (`on_conflict: {:replace, ...}`, en préservant déjà les colonnes d'enrichissement Wikipedia : le précédent existe). Ce remplacement uniforme doit devenir conditionnel PAR LIGNE ET PAR COLONNE : pour chaque colonne appartenant à un champ métier surchargeable, l'update `ON CONFLICT` garde la valeur en place quand le champ figure dans `overridden_fields`, sinon prend `EXCLUDED`. Le mapping champ métier -> colonnes est celui centralisé en #034 (une seule source de vérité, partagée entre `apply_field_override/3` et la construction du fragment d'upsert). Les colonnes n'appartenant à aucun champ surchargeable (`kind`, `sitelink_count`, `wiki_url_*`, etc.) restent remplacées comme avant. La préservation est ainsi atomique, dans le même statement que l'upsert : aucune fenêtre où la valeur corrigée serait écrasée puis réappliquée.

La journalisation des divergences est l'affaire de Contributions, pas d'Atlas (la table `conflicts` vit dans son schéma) : après chaque lot upserté, `ImportEvents` appelle `Amanogawa.Contributions.record_sync_divergences/1` avec le même lot normalisé (appel de façade à façade, autorisé par `.claude/rules/architecture.md` ; Ingestion appelle déjà la façade Atlas de la même manière). Pour chaque override accepté portant sur un QID du lot, la valeur Wikidata entrante du champ est comparée au snapshot `wikidata_value_at_acceptance` :

- égale au snapshot : rien, Wikidata n'a pas bougé sur ce champ ;
- égale à la valeur proposée par l'override (comparaison sur payload normalisé) : Wikidata a rejoint la correction (boucle vertueuse, principe de redistribution) ; l'override passe à `:superseded`, le marqueur est retiré via `Amanogawa.Atlas.release_field_override/3` (la valeur affichée ne change pas : elle est identique des deux côtés), révision `:superseded` journalisée ;
- différente des deux : conflit ouvert (upsert sur l'index partiel unique de #034 : un seul conflit ouvert par override, `wikidata_value` et `detected_at` rafraîchis si Wikidata change encore).

Enfin, l'examen : façade `list_open_conflicts/1` (ordre chronologique) et `resolve_conflict/3` (relecteur, décision `:keep_override` ou `:adopted_wikidata`, motif public journalisé en révision). Garder l'override rafraîchit le snapshot avec la nouvelle valeur Wikidata (le même écart ne re-signale pas à chaque sync) ; adopter Wikidata libère le champ via `release_field_override/3` et passe l'override à `:superseded`. Une LiveView minimale `/relecture/conflits` rend cela actionnable ; elle introduit le gating relecteur (hook `on_mount(:require_reviewer)` et plug `require_reviewer` dans `AmanogawaWeb.UserAuth`, live_session `:require_reviewer`) que #037 réutilisera pour la file de relecture.

Impact système : `EnrichSummaries` n'est pas concerné (colonnes d'extraits, non surchargeables) ; la sync des liens (`ImportLinks`, `on_conflict: :nothing`) ne supprime rien donc ne peut rien écraser ; les événements `origin: :contribution` (identifiant `L...`) sont hors d'atteinte de la sync par construction (cible de conflit `qid`).

## User Story

> En tant que relecteur, je veux que la synchronisation mensuelle préserve les corrections acceptées tout en me signalant chaque divergence avec Wikidata, afin qu'aucune des deux couches n'écrase jamais l'autre en silence.

---

## Tâches

- [ ] `Amanogawa.Atlas.upsert_events/1` : remplacer le `on_conflict: {:replace, @wikidata_columns}` par un update `ON CONFLICT` construit avec des fragments `CASE WHEN <champ> = ANY(overridden_fields) THEN <valeur en place> ELSE EXCLUDED.<colonne> END` pour chaque colonne d'un champ surchargeable, à partir du mapping centralisé de #034 ; documenter dans le moduledoc que la préservation est atomique et par ligne.
- [ ] `Amanogawa.Contributions.record_sync_divergences/1` : prend le lot normalisé (mêmes maps que `upsert_events/1`), charge en UNE requête les overrides `:accepted` des QID du lot, applique la logique trois-cas ci-dessus (rien / superseded / conflit ouvert ou rafraîchi), retourne des compteurs `%{unchanged:, superseded:, conflicts_opened:, conflicts_refreshed:}` pour le résumé de sync.
- [ ] `Amanogawa.Ingestion.Workers.ImportEvents` : appeler `record_sync_divergences/1` après chaque `Amanogawa.Atlas.upsert_events/1` (jamais en dry run), agréger les compteurs dans les métriques du `SyncRun` existant.
- [ ] Façade Contributions : `list_open_conflicts/1` (chronologique, pagination), `resolve_conflict/3` (vérification du rôle relecteur, motif public obligatoire borné, les deux résolutions ci-dessus, transactionnel, révision journalisée).
- [ ] `AmanogawaWeb.UserAuth` : `on_mount(:require_reviewer)` (redirige avec flash neutre un connecté non relecteur, redirige vers `/connexion` un anonyme) et plug conn `require_reviewer` ; routeur : live_session `:require_reviewer` (nom unique, jamais dupliqué, règle F07) derrière `pipe_through [:browser, :authenticated]`.
- [ ] LiveView `AmanogawaWeb.ConflictsLive` sur `/relecture/conflits` : liste chronologique des conflits ouverts (streams, pas de requête dans `mount/3`), pour chacun : événement (libellé + QID), champ, valeur de l'override, nouvelle valeur Wikidata, dates ; actions "garder la correction" / "adopter Wikidata" avec motif obligatoire ; textes fr/en (Gettext).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `record_sync_divergences/1` avec une valeur entrante égale au snapshot ne crée rien ; avec une valeur divergente crée un conflit ouvert portant la valeur Wikidata entrante.
- [ ] **Happy path** : valeur entrante égale à la valeur proposée : override `:superseded`, marqueur retiré, valeur affichée inchangée, révision journalisée.
- [ ] **Edge case** : deux syncs successives avec la même divergence : un seul conflit ouvert, `detected_at` et `wikidata_value` rafraîchis (pas de doublon, index partiel).
- [ ] **Error case** : `resolve_conflict/3` par un non-relecteur, ou sans motif, ou sur un conflit déjà résolu : erreur taguée, aucun effet en base.
- [ ] **Limit case** : lot de 500 événements dont aucun n'a d'override : `record_sync_divergences/1` fait une seule requête et ne touche rien (pas de N+1, vérifiable par le nombre de requêtes ou par la structure du code).

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout sous-ensemble généré de champs surchargeables marqués dans `overridden_fields`, rejouer `upsert_events/1` avec des valeurs Wikidata arbitraires préserve exactement les colonnes des champs marqués et remplace exactement celles des champs non marqués (l'invariant central de la feature, sous forme exécutable).

### Doctests (si applicable)

- [ ] Non applicable : toutes les fonctions touchent la base.

### Tests d'intégration

- [ ] **Intégration (DataCase, sync + overrides)** : scénario complet : événement importé -> override accepté sur `begin_date` (#034) -> nouvel upsert simulant la sync mensuelle avec une date Wikidata différente -> la date affichée n'a pas bougé, un conflit est ouvert -> `resolve_conflict(:adopted_wikidata)` -> la date Wikidata est restaurée, le conflit résolu, l'override `:superseded`, tout est journalisé en révisions.
- [ ] **Intégration (DataCase)** : même scénario avec `resolve_conflict(:keep_override)` : la correction reste affichée, le snapshot est rafraîchi, et un troisième upsert avec la MÊME valeur Wikidata ne rouvre pas de conflit.
- [ ] **Intégration (Oban.Testing, ImportEvents)** : un run d'import (fixtures SPARQL, Mox) sur un corpus contenant un événement surchargé journalise la divergence et reporte les compteurs dans le `SyncRun` ; en dry run, rien n'est journalisé.
- [ ] **Intégration (LiveViewTest, ConflictsLive)** : relecteur : la page liste les conflits et les deux résolutions fonctionnent avec motif ; connecté non relecteur : redirection avec flash neutre ; anonyme : redirection vers `/connexion`.

### Tests end-to-end (si applicable)

- [ ] Non applicable ici (le parcours relecteur E2E est couvert en #039).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/atlas.ex` (upsert conditionnel ; le mapping centralisé de #034)
  - `lib/amanogawa/contributions.ex` (`record_sync_divergences/1`, `list_open_conflicts/1`, `resolve_conflict/3`), `lib/amanogawa/contributions/conflict.ex`
  - `lib/amanogawa/ingestion/workers/import_events.ex` (appel post-lot, compteurs)
  - `lib/amanogawa_web/user_auth.ex` (hook et plug relecteur), `lib/amanogawa_web/router.ex` (live_session `:require_reviewer`)
  - `lib/amanogawa_web/live/conflicts_live.ex`
  - `test/amanogawa/atlas_test.exs`, `test/amanogawa/contributions_test.exs`, `test/amanogawa/ingestion/workers/import_events_test.exs`, `test/amanogawa_web/live/conflicts_live_test.exs`, `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : vue d'ensemble F08 (décision de cadrage : "la sync ne touche JAMAIS un champ ayant un override accepté mais journalise les divergences"), #034 (mapping, snapshots), ADR 0003 (sync mensuelle), `docs/ops/sync.md` (sera mis à jour en #039), `.claude/rules/testing.md` (Oban.Testing, jamais d'appel Wikimedia en test).
- **Compétences requises** : `Ecto.Query.API.fragment/1` dans un `on_conflict`, `insert_all` avancé, Oban (workers, testing), Mox et fixtures SPARQL existantes.
- **Points d'attention** :
  - La comparaison de divergence se fait sur payloads NORMALISÉS (mêmes règles que le stockage : dates aplaties avec précision, coordonnées arrondies à l'identique) ; une différence de représentation ne doit pas fabriquer de faux conflit.
  - `record_sync_divergences/1` s'exécute APRÈS l'upsert du lot mais lit les valeurs entrantes du lot, pas la base (la base contient déjà le résultat préservé) : c'est le lot qui porte ce que Wikidata "voulait" écrire.
  - Ne pas élargir `@max_batch_size` : les fragments CASE ajoutent du texte SQL, pas des paramètres ; vérifier tout de même que le statement reste raisonnable.
  - Le nom de live_session `:require_reviewer` ne doit jamais être dupliqué (leçon F07), et le plug conn reste nécessaire en plus du hook (le websocket ne rejoue pas le pipeline).
  - La page conflits est volontairement minimale : la file de relecture riche (diff, appels) arrive en #037 ; ne pas anticiper ici.
