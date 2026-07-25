# Issue #038 -- Transparence publique et RGPD des contributions

**Feature :** F08 -- Éditeur collaboratif éthique
**Priorité :** Haute
**Estimation :** 12h
**Prérequis :** #037

---

## Contexte

Le workflow complet existe (#034 à #037) ; cette issue le rend intégralement PUBLIC et met les droits RGPD en cohérence. La transparence n'est pas une page vitrine, c'est le mécanisme de confiance du projet (ADR 0008 : "chaque révision est publique, datée, attribuée ; les règles de modération sont publiées ; les décisions sont journalisées et appelables").

Quatre livrables :

1. **`/contributions`** : flux chronologique PUR de toutes les contributions (décision de cadrage : aucun tri algorithmique, aucune mise en avant). Chaque entrée : date, auteur (pseudonyme `display_name`, résolu côté web via `Amanogawa.Accounts.display_names_by_ids/1`, jamais l'email ; "compte supprimé" si anonymisé), événement concerné (libellé + identifiant), champ ou kind, statut. Filtres FACTUELS uniquement : statut, événement (`?event=Q...`), pagination keyset. Page accessible sans compte (live_session `:current_user` posée en #037 pour le détail : l'index la rejoint). Le détail `/contributions/:id` (route posée en #037) est complété : valeurs avant/après formatées selon leur précision, justification et source, toutes les révisions datées (proposition, décision avec motif, appel, issue d'appel), attribution.
2. **Historique par événement dans l'EventPanel** : section sobre en bas du panneau : nombre de corrections acceptées et en attente, lien "voir l'historique" vers `/contributions?event=<id>` ; si un champ affiché provient d'un override accepté, mention discrète "valeur corrigée par la communauté, source à l'appui" avec lien vers la contribution : l'utilisateur sait TOUJOURS ce qu'il lit (couche Wikidata ou surcouche locale).
3. **`/moderation`** : les règles publiées (critères d'acceptation : source vérifiable exigée, exactitude factuelle, neutralité ; motifs de rejet types ; fonctionnement de l'appel ; qui relit, y compris la limite V1 "le même relecteur peut trancher un appel") et des statistiques agrégées FACTUELLES : totaux par statut, propositions par mois, délai médian de décision, nombre de conflits sync ouverts. AUCUN classement de contributeurs, aucun "top", aucune série (anti-dark-patterns). Servie par le pipeline `:static_page` (sans cookie) avec les stats calculées par une requête d'agrégation de la façade Contributions.
4. **RGPD** : l'export de `/compte/export` s'étend aux contributions : `AmanogawaWeb.AccountController.export/2` compose `Amanogawa.Accounts.export_user_data/1` et `Amanogawa.Contributions.export_user_contributions/1` (overrides de l'auteur avec leurs révisions et textes d'appel) et passe `format_version` à 2 : la composition se fait dans la couche WEB, Accounts n'apprend jamais l'existence de Contributions (frontières de contextes, la structure versionnée "une clé par contexte" de #033 était prévue pour ça). La suppression de compte anonymise les contributions au lieu de les supprimer : `Amanogawa.Contributions.anonymize_user/1` (met `author_id` des overrides et `actor_id` des révisions de cet utilisateur à nil, journalise une révision `:anonymized` par override touché), appelée par le parcours de suppression d'`AccountLive` AVANT `Amanogawa.Accounts.delete_user/1`.

**Arbitrage RGPD documenté (décision de cadrage)** : les contributions acceptées font partie de l'historique public cohérent du commun, comme sur un wiki ; les supprimer casserait la traçabilité des données affichées (une correction visible sur la carte sans source ni historique serait un écrasement silencieux a posteriori). L'effacement (article 17) s'applique aux données personnelles : email, pseudonyme et rattachement identifiant sont réellement supprimés (le pseudonyme disparaît avec la ligne `accounts.users`, les contributions n'en gardent aucune copie : l'affichage repose sur la jointure web, qui rend "compte supprimé" dès que `author_id` est nil). Le contenu factuel sourcé reste, au titre de l'intérêt légitime et des finalités d'archive dans l'intérêt public (article 17.3.d) ; la politique de confidentialité l'annonce AVANT la première contribution, et le formulaire de proposition (#036) y renvoie. Les justifications restent publiées : la règle publiée sur `/moderation` interdit d'y placer des données personnelles et la relecture le vérifie avant acceptation.

Impact système : routes publiques `/contributions` (index) et `/moderation`, extension d'EventPanel, export version 2, parcours de suppression modifié, politique de confidentialité amendée.

## User Story

> En tant que visiteur, même sans compte, je veux consulter l'historique complet des contributions, les règles de modération et chaque décision motivée, et en tant que contributeur, je veux exporter mes contributions et savoir exactement ce qui survit, anonymisé, à la suppression de mon compte.

---

## Tâches

- [ ] Façade Contributions : `list_public/1` (chronologique pur, filtres statut et event, pagination keyset), `event_contribution_summary/1` (compteurs acceptées/en attente + champs actuellement surchargés d'un événement), `public_stats/0` (agrégats de `/moderation`), `export_user_contributions/1`, `anonymize_user/1` (transactionnel, idempotent).
- [ ] LiveView `AmanogawaWeb.ContributionsLive` sur `/contributions` : streams, filtres factuels par l'URL (partageables), pagination "charger plus" sobre, entrées liant vers `/contributions/:id` ; compléter `ContributionLive` (détail #037) avec révisions complètes et formatage par précision.
- [ ] Résolution des attributions côté web : helper unique (composant ou fonction partagée) appelant `Amanogawa.Accounts.display_names_by_ids/1` en une requête par page (jamais de N+1, jamais d'email), rendant "compte supprimé" pour `author_id` nil.
- [ ] `AmanogawaWeb.Components.EventPanel` : section historique (compteurs + lien filtré) et mention "valeur corrigée" par champ surchargé (lu depuis `overridden_fields`, déjà chargé avec l'événement) ; garder la section discrète, le panneau reste d'abord une fiche de lecture.
- [ ] Page `/moderation` (`PageController` + template, pipeline `:static_page`) : règles rédigées fr/en (Gettext), stats agrégées de `public_stats/0`, lien vers `/contributions` ; vérifier qu'aucun cookie n'est déposé (test du pipeline existant étendu).
- [ ] Export RGPD : `export_user_contributions/1` (overrides avec statuts, valeurs, justifications, révisions authored, appels), composition dans `AccountController.export/2`, `format_version: 2` ; toujours aucun hash ni donnée d'autrui (les motifs des relecteurs sont publics, ils peuvent figurer dans l'export de l'auteur).
- [ ] Suppression de compte : `AccountLive` appelle `Contributions.anonymize_user/1` puis `Accounts.delete_user/1` ; l'ordre garantit qu'un crash entre les deux laisse un état rattrapable (contributions déjà anonymes, compte encore supprimable), jamais d'attribution orpheline ; textes de confirmation mis à jour : la suppression annonce explicitement l'anonymisation des contributions publiques.
- [ ] Politique de confidentialité (`privacy.html.heex`, fr/en) : section contributions : caractère public et permanent de l'historique, pseudonyme, contenu de l'export, anonymisation à la suppression et sa base légale (article 17.3.d), interdiction des données personnelles dans les justifications.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `anonymize_user/1` met à nil `author_id` et `actor_id` de toutes les lignes de l'utilisateur, journalise `:anonymized`, et ne touche ni statuts, ni valeurs, ni motifs ; `export_user_contributions/1` restitue toutes ses contributions avec révisions.
- [ ] **Edge case** : `anonymize_user/1` rejouée (idempotence, crash entre anonymisation et suppression) ne double pas les révisions `:anonymized` et reste sans effet ; export d'un utilisateur sans contribution : liste vide, jamais d'erreur.
- [ ] **Error case** : `list_public/1` avec un filtre de statut inconnu ou un identifiant d'événement mal formé : rejet borné côté serveur (paramètres validés), jamais d'exception.
- [ ] **Limit case** : `public_stats/0` sur base vide retourne des zéros cohérents ; pagination keyset stable quand deux contributions partagent le même instant.

### Property-based tests (si applicable)

- [ ] **Property** (StreamData) : pour tout utilisateur généré avec un nombre arbitraire de contributions et révisions, `Jason.encode!` de l'export composé réussit et ne contient jamais l'email d'un AUTRE utilisateur ni aucun `author_id` tiers en clair au-delà des attributions publiques (l'export est un sérialiseur qui ne lève jamais, précédent #033).

### Doctests (si applicable)

- [ ] Non applicable : façade et LiveViews, tout touche la base.

### Tests d'intégration

- [ ] **Intégration (LiveViewTest, ContributionsLive)** : anonyme : le flux liste les contributions dans l'ordre chronologique strict (assertion sur l'ordre exact), les filtres statut et événement fonctionnent par l'URL, l'attribution affiche le pseudonyme et jamais l'email.
- [ ] **Intégration (LiveViewTest, détail)** : la page d'une contribution rejetée puis appelée montre les quatre révisions datées avec motifs ; les dates avant/après sont formatées selon leur précision.
- [ ] **Intégration (LiveViewTest, EventPanel)** : un événement avec override accepté montre la mention "valeur corrigée" et le lien filtré ; un événement vierge ne montre aucune section vide bavarde.
- [ ] **Intégration (ConnCase, /moderation)** : la page rend règles et stats dans les deux locales, sans Set-Cookie (pipeline `:static_page`).
- [ ] **Intégration (ConnCase, export v2)** : l'export d'un contributeur porte `format_version: 2` et sa clé `contributions` ; un utilisateur pré-F08 exporte sans erreur avec une liste vide.
- [ ] **Intégration (LiveViewTest, suppression)** : suppression d'un compte contributeur : le compte disparaît, `/contributions` affiche "compte supprimé" sur ses lignes, les valeurs corrigées restent sur la carte, l'historique reste consultable ; re-création d'un compte avec le même email : aucune récupération des anciennes contributions.

### Tests end-to-end (si applicable)

- [ ] Couvert par #039 (le parcours contributeur vérifie le flux public de bout en bout).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa/contributions.ex` (list_public, summary, stats, export, anonymize)
  - `lib/amanogawa_web/live/contributions_live.ex`, `lib/amanogawa_web/live/contribution_live.ex` (complété), `lib/amanogawa_web/components/event_panel.ex`
  - `lib/amanogawa_web/controllers/page_controller.ex` + `page_html/moderation.html.heex`, `lib/amanogawa_web/controllers/account_controller.ex`, `lib/amanogawa_web/live/account_live.ex`, `lib/amanogawa_web/controllers/page_html/privacy.html.heex`, `lib/amanogawa_web/router.ex`
  - `test/amanogawa/contributions_test.exs` (extension), `test/amanogawa_web/live/contributions_live_test.exs`, `test/amanogawa_web/controllers/page_controller_test.exs` (extension), `test/amanogawa_web/controllers/account_controller_test.exs` (extension), `test/amanogawa_web/live/account_live_test.exs` (extension), `priv/gettext/*/LC_MESSAGES/*.po`
- **Documentation de référence** : vue d'ensemble F08 (arbitrages : anonymisation, composition web de l'export), #033 (structure d'export versionnée, suppression), #034 (append-only), ADR 0008, articles 17 et 20 du RGPD (cnil.fr), modèle Wikipedia de conservation des historiques après suppression de compte.
- **Compétences requises** : LiveView (streams, pagination keyset), agrégations Ecto, RGPD opérationnel, rédaction fr/en de règles de modération et de contenu légal.
- **Points d'attention** :
  - "Chronologique pur" est une exigence testée, pas un défaut d'implémentation : l'ordre est `inserted_at` (+ id en départage), rien d'autre, et aucun code de scoring ne doit exister nulle part.
  - La jointure d'attribution se fait par lot et par page ; ne jamais stocker le pseudonyme dans `contributions` (sinon l'anonymisation devient un ramasse-miettes de copies).
  - `anonymize_user/1` puis `delete_user/1` : deux transactions, deux contextes ; l'ordre est un choix de sûreté à documenter dans le moduledoc du parcours de suppression.
  - Les stats de `/moderation` sont recalculées à la demande (volumes V1 faibles) ; pas de cache prématuré, noter le seuil de révision si la page devient chère.
  - La politique de confidentialité ne doit jamais promettre plus que ce que le code fait (vitre cassée légale, précédent #033) : relire les deux versions linguistiques contre le comportement réel.
  - Le formulaire de #036 renvoie vers la politique et vers `/moderation` : vérifier les liens croisés à la fin.
