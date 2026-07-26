# Modération (issue #039)

Procédure d'exploitation pour l'opérateur qui fait vivre l'éditeur collaboratif (F08) : promouvoir un relecteur, rythme de relecture conseillé, examen des conflits de synchronisation, conduite à tenir face à un compte abusif. Les règles PUBLIQUES de modération (critères d'acceptation, motifs de rejet, fonctionnement de l'appel) sont sur `/moderation` : ce document est réservé à l'opérateur, il ne les répète pas.

## Promouvoir un relecteur

Choix assumé de la version 1 (F08 overview, décision de cadrage) : aucune interface d'administration, la promotion est une opération manuelle en base de données, réservée à un mainteneur de confiance de son propre déploiement.

Depuis `psql` (ou tout client SQL connecté à la base de production) :

```sql
-- Trouver l'identifiant du compte à promouvoir (l'utilisateur doit déjà
-- s'être connecté au moins une fois par lien magique, donc déjà exister
-- dans accounts.users).
select id, email, display_name, role
from accounts.users
where email = 'relecteur@exemple.org';

-- Promouvoir.
update accounts.users
set role = 'reviewer'
where email = 'relecteur@exemple.org';

-- Vérifier.
select id, email, display_name, role
from accounts.users
where email = 'relecteur@exemple.org';
```

Un relecteur promu accède immédiatement à `/relecture` (file de relecture) et `/relecture/conflits` (conflits de synchronisation) dès sa prochaine requête, sans redémarrage ni redéploiement : le rôle est lu à chaque requête authentifiée (`AmanogawaWeb.UserAuth.require_reviewer/2`).

Rétrograder un relecteur suit le chemin inverse :

```sql
update accounts.users
set role = 'user'
where email = 'ancien-relecteur@exemple.org';
```

Rétrograder ne touche à aucune de ses décisions passées (`contributions.revisions` conserve l'historique complet, append-only, quel que soit le rôle actuel de l'auteur de la révision) : seules les actions FUTURES lui sont refusées.

## Rythme de relecture conseillé

La file (`/relecture`) est strictement chronologique FIFO (F08 overview : "aucun tri algorithmique"), sans notion de priorité ni d'urgence assignable. Pour un projet à volumétrie V1 faible (mainteneur solo ou petite équipe de confiance) :

- Consulter `/relecture` au moins une fois par jour ouvré : une proposition qui attend une semaine décourage son auteur (risque documenté dans la feature, "Charge de modération sur un projet solo").
- Traiter les propositions ET les appels dans le même passage (les deux apparaissent dans la même file, un appel gardant la date de la proposition d'origine, jamais celle de l'appel).
- Un motif de décision est OBLIGATOIRE et public (`/contributions/:id`) : le rédiger comme si l'auteur allait le lire immédiatement, parce qu'il le peut (email de notification envoyé à la décision).
- Ne jamais décider sa propre proposition (anti auto-relecture, refusé côté serveur de toute façon) : en solo, cela borne de fait ce qu'un mainteneur peut proposer lui-même sans un second relecteur.

## Examiner les conflits de synchronisation

`/relecture/conflits` liste les divergences entre une correction locale acceptée et une valeur Wikidata qui a bougé depuis (F08 overview, issue #035). Quand les examiner :

- **Après chaque synchronisation mensuelle** (`docs/ops/sync.md`, section "Divergences et conflits") : le résumé du `SyncRun` (`ingestion.sync_runs.counts`) porte les compteurs `sync_unchanged`, `sync_superseded`, `sync_conflicts_opened`, `sync_conflicts_refreshed`. Un `sync_conflicts_opened` ou `sync_conflicts_refreshed` non nul signale qu'au moins un conflit attend une décision.
- Depuis `iex -S mix`, sans attendre le prochain passage sur `/relecture/conflits` :

  ```elixir
  Amanogawa.Ingestion.last_sync_run(:events).counts
  ```

- Pour chaque conflit ouvert, deux résolutions possibles (`Amanogawa.Contributions.resolve_conflict/3`, exposées comme les deux boutons de `/relecture/conflits`) :
  - **Garder la correction locale** : la divergence Wikidata est ignorée pour ce champ, le snapshot de référence est rafraîchi (la même divergence ne re-signale pas au prochain mois).
  - **Adopter Wikidata** : la correction locale est retirée (`overridden_fields` perd ce champ), la valeur Wikidata redevient affichée ; l'override passe à `:superseded`.
- Un conflit non résolu reste ouvert indéfiniment sans dégrader la carte (le champ conserve la correction locale par défaut, comportement sûr par construction) : il n'y a pas d'urgence à décider dans l'heure, mais un conflit ancien mérite d'être examiné avant le mois suivant pour éviter l'accumulation.

## Conduite à tenir face à un compte abusif

- **Vandalisme ou spam de propositions** : les quotas anti-abus (Hammer, `AmanogawaWeb.RateLimit` / `Amanogawa.Contributions.ProposalThrottle`) bornent déjà le débit par utilisateur et par IP ; rejeter chaque proposition abusive avec un motif public factuel ("source absente", "contenu non neutre") suffit dans l'immense majorité des cas, la file de relecture restant le seul filtre avant la carte.
- **Comportement répété malgré les rejets** : aucune fonctionnalité de bannissement dédiée en V1. Le seul levier disponible est la suppression du compte par son propriétaire lui-même (`/compte`) ; un opérateur ne peut pas supprimer le compte d'un tiers depuis cette version (RGPD : la suppression est un droit exercé par la personne concernée, pas un pouvoir de modération). En pratique, un compte qui ne propose que du contenu rejeté épuise vite son intérêt à continuer : le vrai garde-fou est que RIEN d'un compte abusif n'atteint jamais la carte sans une décision explicite d'un relecteur.
- **Rappel important** : si un contributeur abusif supprime lui-même son compte (ou si un mainteneur l'y invite), ses contributions PUBLIQUES ne sont PAS effacées : elles sont anonymisées ("compte supprimé", `Amanogawa.Contributions.anonymize_user/1`, article 17.3.d du RGPD, voir `/confidentialite`). L'historique public reste cohérent, comme sur un wiki, mais un opérateur qui espérait faire disparaître un contenu litigieux par cette voie doit savoir que ce contenu (accepté) reste visible : le rejeter à la relecture, avant qu'il ne soit accepté, est le seul moment où il ne rejoint jamais l'historique public.

## Voir aussi

- `/moderation` : les règles publiées (critères d'acceptation, motifs de rejet types, fonctionnement de l'appel), et les statistiques agrégées factuelles.
- `docs/ops/sync.md` : la synchronisation mensuelle, ses compteurs de divergences, le renvoi vers cette section.
- `docs/adr/0009-surcouche-de-contributions.md` : la décision structurante de résolution des overrides et de coexistence avec la synchronisation.
