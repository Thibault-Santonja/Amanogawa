# Issue #027 -- Page Sources / À propos, mentions légales et confidentialité

**Feature :** F06 -- Déploiement et pages légales
**Priorité :** Haute
**Estimation :** 6h
**Prérequis :** #004

---

## Contexte

Amanogawa est construit entièrement sur des communs (ADR 0008). L'attribution systématique des sources est un principe fondateur (`.claude/rules/ethics.md`) et une obligation de licence pour Wikipedia (CC BY-SA 4.0) et Cliopatria (CC BY 4.0). Avant la mise en ligne publique du MVP, le site doit exposer : une page Sources / À propos avec toutes les attributions, des mentions légales, une politique de confidentialité, et le lien vers le code source AGPL-3.0 (l'article 13 de l'AGPL impose d'offrir le code source aux utilisateurs du service en réseau).

Le problème résolu : sans ces pages, la mise en production violerait les licences des sources et les principes éthiques du projet. C'est un critère de sortie du MVP.

Insertion dans l'architecture : pages statiques servies par un controller Phoenix classique (`PageController`), pas de LiveView (aucun état, aucune interactivité) ; templates HEEx utilisant le layout, les design tokens Tailwind v4 et le dark mode livrés par l'issue #004 ; liens ajoutés au footer du layout racine, donc visibles sur toutes les pages. Contenu bilingue via Gettext (politique de langue : contenu utilisateur en français et anglais).

Impact sur le reste du système : le footer du layout est modifié (visible partout) ; les crédits affichés sur la carte elle-même (attribution courte MapLibre) restent du ressort de F05 (#025) et du fond de carte (#005), cette page en est la version exhaustive et pointe vers eux.

## User Story

> En tant que visiteur, je veux consulter une page listant toutes les sources de données, leurs licences et les informations légales du site, afin de connaître la provenance des contenus, leurs limites, et mes garanties en matière de vie privée.

---

## Tâches

- [ ] Ajouter les routes dans `lib/amanogawa_web/router.ex` : `GET /sources`, `GET /mentions-legales`, `GET /confidentialite`, servies par `AmanogawaWeb.PageController` (actions `sources`, `legal`, `privacy`).
- [ ] Rédiger le contenu de la page Sources (fr + en), une section par source, chacune avec nom, rôle dans Amanogawa, licence exacte et liens (source et texte de licence) :
  - **Wikidata** : données structurées des événements, licence CC0 1.0 (attribution donnée par bonne pratique bien que non requise), lien vers wikidata.org et vers le texte CC0.
  - **Wikipedia** : résumés d'articles, licence CC BY-SA 4.0, lien vers le texte de la licence ; rappel que chaque extrait affiché dans l'application est accompagné d'un lien vers son article d'origine et de la mention de licence.
  - **Cliopatria (Seshat Global History Databank)** : frontières historiques de -3400 à 2024, licence CC BY 4.0, attribution aux auteurs du jeu de données, lien vers le dépôt Zenodo (v0.1.3) et vers le texte de la licence.
  - **historical-basemaps** : zones d'influence préhistoriques (avant -3400), licence GPL-3.0, lien vers le dépôt GitHub et vers le texte de la licence.
  - **Fond de carte** : attribution du fournisseur retenu par l'issue #005 (OpenFreeMap ou Protomaps auto-hébergé) et, dans les deux cas, attribution des données OpenStreetMap (ODbL, "© OpenStreetMap contributors") avec liens.
- [ ] Formuler clairement l'imprécision des frontières sur la page Sources, en encadré visible : les frontières affichées sont des "zones d'influence approximatives par nature", en particulier pour les périodes anciennes ; les tracés ne constituent aucune prise de position sur des différends territoriaux passés ou présents.
- [ ] Rédiger les mentions légales (fr + en) : éditeur du site (nom, contact email), directeur de la publication, hébergeur (Hetzner Online GmbH, adresse complète), licence du code (AGPL-3.0) avec lien vers le dépôt.
- [ ] Rédiger la politique de confidentialité (fr + en), courte et honnête : aucune donnée personnelle collectée en phase 1, aucun cookie (y compris pour les visiteurs anonymes), aucun traceur, aucun service tiers d'analyse ; seuls des journaux techniques serveur (nécessaires à la sécurité et au bon fonctionnement, sans profilage) sont conservés pour une durée courte, cohérente avec la rétention définie en #028.
- [ ] Ajouter au footer du layout racine : liens vers les trois pages, et mention "Code source sous licence AGPL-3.0" pointant vers `https://github.com/Thibault-Santonja/Amanogawa` (satisfait l'obligation d'offre de source de l'AGPL pour un service réseau).
- [ ] Vérifier qu'aucune de ces pages ne pose de cookie : pas de session initiée, aucun en-tête `set-cookie` pour un visiteur anonyme (cohérence entre la promesse de la politique de confidentialité et le comportement réel).
- [ ] Extraire toutes les chaînes via Gettext et fournir les traductions fr et en (`priv/gettext/`).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `GET /sources` répond `200` et le HTML contient les cinq sections de sources (Wikidata, Wikipedia, Cliopatria, historical-basemaps, fond de carte), chacune avec le nom de sa licence exacte (CC0 1.0, CC BY-SA 4.0, CC BY 4.0, GPL-3.0, ODbL).
- [ ] **Happy path** : `GET /mentions-legales` et `GET /confidentialite` répondent `200` avec l'hébergeur (Hetzner) pour l'une, et les affirmations "aucun cookie" et "aucune donnée personnelle collectée" pour l'autre.
- [ ] **Edge case** : la page Sources contient la formulation d'imprécision des frontières ("zones d'influence approximatives par nature") et les `href` attendus (wikidata.org, dépôt Zenodo de Cliopatria, dépôt GitHub historical-basemaps, textes de licences, openstreetmap.org).
- [ ] **Edge case** : le footer rendu sur la page d'accueil contient les liens vers les trois pages et le lien AGPL vers le dépôt GitHub.
- [ ] **Error case** : une locale inconnue ou malformée retombe proprement sur le français (locale par défaut) sans erreur 500.
- [ ] **Limit case** : les pages répondent `200` en locale `en` avec le contenu traduit (les affirmations clés sont présentes dans les deux langues).

### Property-based tests (si applicable)

- [ ] Non applicable : contenu statique, aucune logique de transformation de données.

### Doctests (si applicable)

- [ ] Non applicable : controller sans fonction publique pure.

### Tests d'intégration

- [ ] **Intégration** : pour un visiteur anonyme, les réponses de `/`, `/sources`, `/mentions-legales` et `/confidentialite` ne contiennent aucun en-tête `set-cookie` (la promesse zéro cookie est vérifiée par la CI, pas seulement affirmée).
- [ ] **Intégration** : les liens externes des templates portent `rel="noopener noreferrer"` et la CSP stricte du layout reste inchangée sur ces pages (aucun script ou style externe introduit).

### Tests end-to-end (si applicable)

- [ ] **E2E** : dans le parcours critique existant, depuis la page d'accueil, cliquer sur le lien "Sources" du footer affiche la page avec les attributions (PhoenixTest ou Wallaby, selon l'outillage retenu en F01).

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `lib/amanogawa_web/router.ex`
  - `lib/amanogawa_web/controllers/page_controller.ex`
  - `lib/amanogawa_web/controllers/page_html.ex` et `lib/amanogawa_web/controllers/page_html/sources.html.heex`, `legal.html.heex`, `privacy.html.heex`
  - `lib/amanogawa_web/components/layouts/root.html.heex` (footer) ou le composant footer dédié issu de #004
  - `priv/gettext/fr/LC_MESSAGES/*.po`, `priv/gettext/en/LC_MESSAGES/*.po`
  - `test/amanogawa_web/controllers/page_controller_test.exs`
- **Documentation de référence** : ADR 0008 (AGPL et principes éthiques), `.claude/rules/ethics.md` (attribution, zéro tracking), `.claude/memory/data-sources.md` (sources exactes, versions, licences), F05 `000-frontieres-historiques.md` (formulation "zones d'influence"), issue #005 (choix du fond de carte), textes officiels des licences (creativecommons.org, gnu.org, opendatacommons.org).
- **Compétences requises** : Phoenix controllers et HEEx, Gettext, Tailwind v4 avec les tokens de #004, bases des licences libres (CC, GPL, ODbL, AGPL).
- **Points d'attention** :
  - Pas de LiveView ici : des pages statiques n'ont besoin ni d'état ni de socket (et un socket LiveView impliquerait une session, donc un cookie, en contradiction avec la politique de confidentialité).
  - L'attribution exacte du fond de carte dépend du choix tranché en #005 : lire la conclusion de cette issue avant de rédiger la section ; l'attribution OpenStreetMap (ODbL) est requise dans tous les cas envisagés.
  - Aucun tiret cadratin ni demi-cadratin dans les contenus, y compris les chaînes Gettext.
  - Ton factuel et sobre : la politique de confidentialité tient en quelques paragraphes précisément parce qu'il n'y a rien à déclarer ; ne pas gonfler artificiellement.
  - La version courte des crédits affichée sur la carte (contrôle d'attribution MapLibre) relève de #005 et #025 ; vérifier simplement la cohérence des deux niveaux d'attribution.

---

## Addendum (2026-07-24, revue de F06)

La formulation initiale de cette issue exigeait que les réponses de `/` ne contiennent aucun en-tête `set-cookie`. Cette exigence est amendée : la page d'exploration `/` est une LiveView, et le handshake websocket de LiveView exige un jeton CSRF porté par un cookie de session signé. Supprimer ce cookie reviendrait à désactiver la protection CSRF du canal temps réel.

Décision actée : les pages statiques (`/sources`, `/mentions-legales`, `/confidentialite`, `/health`) ne posent aucun cookie (vérifié par test) ; la page `/` pose exactement un cookie de session strictement nécessaire (`_amanogawa_key`, HttpOnly, SameSite=Lax, Secure en production, contenu limité au jeton CSRF, expirant avec la session). La politique de confidentialité documente ce cookie tel quel, et un test verrouille la promesse "exactement un cookie technique" sur `/`.
