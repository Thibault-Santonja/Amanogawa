# 0009. Surcouche de contributions résolue à l'écriture, jamais à la lecture

Date : 2026-07-26
Statut : Accepté

## Contexte

F08 (éditeur collaboratif) ouvre la contribution "à la Wikipedia" sur un corpus qui reste synchronisé mensuellement avec Wikidata (F02, ADR 0003). Trois contraintes non négociables se heurtent :

- **Les données en couches sont un principe fondateur** (ADR 0008) : une donnée issue de Wikidata reste traçable et resynchronisable, une contribution locale ne doit jamais l'écraser silencieusement, ni l'inverse.
- **La synchronisation mensuelle continue de tourner** (`Amanogawa.Ingestion.Workers.ImportEvents`) sur le même corpus que l'éditeur modifie : un upsert Wikidata qui rejouerait une valeur périmée sur un champ corrigé romprait la confiance dans la première contribution venue.
- **La requête viewport est le chemin critique du projet** (ADR 0007 : bbox + fenêtre temporelle + importance, budget p95 sous 300 ms) : elle sert des centaines de milliers d'événements et ne doit gagner aucun coût nouveau pour une fraction de lignes corrigées.

Il faut donc décider OÙ et QUAND la valeur affichée (Wikidata ou corrigée) est calculée, et comment cette décision coexiste avec une resynchronisation qui ne s'arrête jamais.

## Décision

Nous allons résoudre la valeur affichée À L'ÉCRITURE, jamais à la lecture, par une surcouche `contributions.overrides` couplée à une façade Atlas dédiée :

- `contributions.overrides` porte une ligne par champ corrigé (`event_qid`, `field`, `proposed_value`, `source`, `status`), jamais de clé étrangère vers `atlas.events` (les schémas PG restent séparés par contexte, `.claude/rules/architecture.md`) : l'existence de l'événement est vérifiée à l'application, pas contrainte en base.
- À l'acceptation d'un override, `Amanogawa.Contributions` appelle `Amanogawa.Atlas.apply_field_override/3`, seule porte d'entrée : la valeur corrigée est écrite DANS LES COLONNES EXISTANTES de `atlas.events` (le champ métier lui-même, `label_fr`, `begin_year`, `geom`, ...), et le nom du champ est ajouté à une nouvelle colonne `atlas.events.overridden_fields` (tableau de noms). Aucune vue, aucune jointure, aucun second stockage de la valeur affichée : tout lecteur existant (`list_events_geojson/1`, `get_event_summary/1`, l'API JSON publique) sert la valeur corrigée gratuitement, sans modification.
- La valeur Wikidata d'origine est snapshotée dans l'override lui-même (`wikidata_value_at_acceptance`, capturée AU MOMENT de l'acceptation, pas de la proposition) : rien n'est perdu, tout est réversible (`release_field_override/3`).
- L'upsert de synchronisation (`Amanogawa.Atlas.upsert_events/1`) devient un remplacement CONDITIONNEL colonne par colonne : `WHEN <field> = ANY(overridden_fields) THEN <valeur existante> ELSE <valeur entrante>`. Un champ corrigé n'est jamais réécrit par la sync ; les autres champs de la même ligne continuent de se synchroniser normalement.
- Chaque lot synchronisé est comparé, en une requête, aux overrides `:accepted` dont l'`event_qid` apparaît dedans (`Amanogawa.Contributions.record_sync_divergences/1`) : valeur inchangée (rien), Wikidata a rejoint la correction (override `:superseded`, marqueur levé automatiquement), ou divergence réelle (conflit ouvert dans `contributions.conflicts`, examiné par un relecteur, `docs/ops/moderation.md`).
- Un événement d'origine communautaire (jamais vu par Wikidata) entre dans `atlas.events` avec un identifiant local `L<uuid hex>` dans la colonne `qid` existante (format étendu, jamais en collision avec `Q\d+`, donc jamais touché par la sync) et une colonne `origin` (`:wikidata` | `:contribution`).
- La suppression d'un compte anonymise ses contributions plutôt que de les supprimer (`Amanogawa.Contributions.anonymize_user/1` : `author_id`/`actor_id` mis à `nil`, une révision `:anonymized` journalisée par override touché) : l'historique public reste cohérent (une valeur affichée sur la carte garde toujours sa source et son historique), au titre de l'article 17.3.d du RGPD (archivage dans l'intérêt public légitime), la politique de confidentialité l'annonçant avant toute première contribution.

## Conséquences

Positives :
- Le chemin de lecture chaud (viewport, histogramme, API publique) est INCHANGÉ : zéro jointure supplémentaire, zéro coût nouveau, quel que soit le nombre de corrections acceptées.
- Traçabilité et réversibilité complètes : `wikidata_value_at_acceptance` et `overridden_fields` permettent de revenir à la valeur d'origine à tout moment, sans reconstruction ni ré-import.
- L'historique public reste cohérent même après suppression de compte (anonymisation plutôt que suppression) : jamais de valeur affichée sans source ni révision associée.

Négatives :
- Double vérité à maintenir entre les colonnes résolues de `atlas.events` et les snapshots des overrides : un bug de préservation romprait silencieusement le principe fondateur (mitigation : tests d'intégration sync+overrides dédiés, issue #035).
- L'upsert conditionnel colonne par colonne complexifie la requête SQL de synchronisation par rapport à un simple upsert total.

Compromis explicitement acceptés :
- Les liens entre événements (`atlas.event_links`) ne supportent que l'AJOUT en V1 : retirer un lien erroné exigerait des tombstones résistant à la resync mensuelle des relations (`on_conflict: :nothing` réinsérerait un lien supprimé), complexité reportée à une extension future.
- La remontée des corrections locales vers Wikidata (boucle vertueuse avec le commun d'origine, F08 overview) est étudiée mais hors périmètre de cette version : chaque override accepté conserve sa source, matière première d'un futur import inverse.

## Alternatives considérées

**Vue matérialisée** (une vue `atlas.events_resolved` recalculée périodiquement à partir d'`atlas.events` et des overrides acceptés). Rejetée : impose un rafraîchissement à orchestrer (Oban, cron) et une fenêtre de "staleness" entre une acceptation et sa visibilité sur la carte, incompatible avec l'attente d'une correction immédiatement visible ; duplique en outre l'intégralité de la table pour une fraction de lignes réellement corrigées.

**Jointure à la lecture** (chaque requête viewport joint `atlas.events` à `contributions.overrides` pour résoudre la valeur affichée). Rejetée : fait payer à LA requête critique du projet (budget p95 sous 300 ms, des centaines de milliers de lignes par requête) un pivot cross-schéma sur une table en une-ligne-par-champ, pour un cas rare (les corrections restent une fraction infime du corpus) ; viole aussi la séparation stricte des schémas PG par contexte si la jointure devient structurelle.

**Fork complet du corpus sans resync** (l'éditeur travaillerait sur une copie du corpus, détachée de la synchronisation Wikidata dès la première contribution). Rejetée : romprait le principe fondateur des données en couches (ADR 0008) en abandonnant la resynchronisation, qui est la garantie que le corpus reste vivant et à jour ; transformerait chaque contribution en divergence permanente et non arbitrable plutôt qu'en correction ponctuelle et réversible.
