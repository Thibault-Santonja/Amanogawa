# Ajouter une feature ou une issue

Guide pas a pas pour ajouter une nouvelle feature (ou une issue isolee) a
Amanogawa, dans le respect strict du workflow du projet. Il suppose que
l'environnement tourne : voir [getting-started.md](getting-started.md).
Pour la carte des modules et des contextes, voir
[codebase-map.md](codebase-map.md) et [architecture.md](architecture.md).

La regle qui prime sur tout : lire le code existant avant d'ecrire. Chaque
patron decrit ci-dessous existe deja dans le depot ; on le reutilise, on ne
le reinvente pas.

## 1. Workflow documentaire

Toute feature commence par sa documentation, avant la moindre ligne de code.
La convention complete vit dans `.claude/rules/issues.md` et dans
[docs/README.md](../README.md) ; en voici l'application concrete.

### Creer le dossier de feature

Un dossier par feature sous `docs/features/`, en trois chiffres et
kebab-case : `docs/features/NNN-slug/`. Le numero suit celui de la derniere
feature (les huit premieres vont de `001-fondations` a
`008-editeur-collaboratif`).

### Rediger la vue d'ensemble `000-slug.md`

Le fichier `000-<slug>.md` porte la vue d'ensemble. Sa structure, calquee
sur les features existantes (modele de reference :
`docs/features/004-frise-chronologique/000-frise-chronologique.md`) :

- En-tete : `# FNN -- Nom de la feature` puis une ligne de metadonnees
  `> Phase | Priorite | Estimation`.
- `## Resume` : ce que fait la feature, en un paragraphe, avec un renvoi aux
  ADR fondateurs (`docs/adr/`).
- `## Analyse` decoupee en sous-sections : **architecture** (modules et
  contextes touches, frontieres), **securite** (validation, IDOR, rate
  limiting, CSP), **ethique** (attribution des sources, zero tracking,
  etiquette API Wikimedia), **performance** (volumetrie, requetes, index).
- `## User Stories` au format GIVEN / WHEN / THEN.
- `## Issues` : un tableau decoupant la feature en issues, chacune estimee a
  24h maximum (au-dela, on decoupe).

### Rediger les issues `001+.md`

Chaque issue part du squelette `docs/features/000-template.md` (copie et
remplissage). Deux points de convention sont non negociables :

- **Numerotation locale du fichier, id global dans le titre.** Le fichier est
  numerote par feature (`001-*.md`, `002-*.md`, ...), mais le titre porte
  l'id GLOBAL et continu de l'issue : `# Issue #NNN -- Titre`. Exemple reel :
  `docs/features/003-carte-interactive/001-endpoint-events-geojson.md`
  commence par `# Issue #014 -- ...`. L'id global ne change jamais, meme si
  le fichier est renumerote localement.
- **Les prerequis referencent des ids globaux** (`Prerequis : #010, #012`),
  jamais des numeros de fichier.

Le corps de l'issue suit le template : Contexte, User Story, Taches (cases a
cocher), Tests a ecrire (unitaires happy/edge/error/limit, property-based,
doctests, integration, E2E), Notes pour le developpeur (fichiers a creer ou
modifier, documentation de reference, points d'attention).

Un bon exemple complet a lire avant de rediger la sienne :
`docs/features/003-carte-interactive/001-endpoint-events-geojson.md`.

## 2. Workflow git

### Une branche par feature

```
git switch -c feature/NNN-slug
```

Le nom de branche reprend le numero et le slug de la feature (par exemple
`feature/003-carte-interactive`). On ne travaille jamais directement sur
`main`.

### Commits conventionnels

Format impose : `<type>(<scope>): <sujet>`, sujet a l'imperatif, en
minuscules, sans point final, en anglais (les messages de commit sont en
anglais, voir la politique de langue plus bas).

- Types : `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.
- Scopes : `atlas`, `ingestion`, `accounts`, `contributions`, `web`, `map`,
  `timeline`, `infra`, `config`, `deps`.

Exemples : `feat(atlas): add events GeoJSON endpoint`,
`test(map): cover antimeridian bbox decomposition`,
`docs(timeline): document symlog anchors`.

### `mix precommit` avant CHAQUE commit

C'est la meta-regle numero un du projet. La CI
(`.github/workflows/ci.yml`) rejoue exactement cet alias : le faire passer
localement en premier evite un aller-retour. L'alias (`mix.exs`) enchaine,
dans l'ordre et en echouant au premier probleme :

1. `compile --warnings-as-errors`
2. `format --check-formatted`
3. `credo --strict`
4. `sobelow --exit --skip`
5. `assets.build`
6. `cmd --cd assets npm test` (tests unitaires JS)
7. `test` (suite Elixir, hors `:e2e`)

Aucun commit ne part tant que `mix precommit` n'est pas vert : on corrige
TOUTES les erreurs et TOUS les avertissements, sans exception.

### Verifier ce qui ne doit jamais partir

Avant de committer, s'assurer que `.claude/`, `CLAUDE.md` et `AGENTS.md` ne
sont pas indexes (`git restore --staged` sinon). Verifier l'absence de
tiret cadratin ou demi-cadratin et de toute reference a un outillage
d'assistance.

### PR, revue, merge

Ouvrir une PR vers `main`. Le projet applique une revue rigoureuse : revue
qualite (respect des regles `.claude/rules/`, couverture, idiomes) et revue
securite (OWASP, IDOR, validation, CSP, `sobelow`). La CI doit etre verte,
E2E comprise (job dedie dans `ci.yml`). Le merge ne se fait qu'apres revue.

## 3. Patrons a reutiliser

Chaque besoin recurrent a deja son patron dans le depot. On l'imite plutot
que d'inventer. Les frontieres detaillees sont dans
[architecture.md](architecture.md), les emplacements dans
[codebase-map.md](codebase-map.md).

### Nouveau champ de domaine

Contexte + facade + migration + changeset.

- Ajouter la colonne par une migration dans le bon schema PostgreSQL
  (`atlas`, `ingestion`, `accounts`, `contributions`), le schema Ecto
  declarant son `@schema_prefix`.
- Ajouter le champ au schema Ecto et le valider dans son `changeset/2`
  (validation a la frontiere ; au-dela, la donnee est de confiance).
- N'exposer l'operation que par la facade du contexte
  (`Amanogawa.Atlas`, `lib/amanogawa/atlas.ex`) : le web et les autres
  contextes passent par la facade, jamais par un module interne.

### Nouvel endpoint JSON

Params valide + controleur mince + module de requetes + pipeline rate-limite.
Exemple de reference : l'endpoint `GET /api/events` (issue #014).

- Un changeset schemaless de validation des parametres bruts :
  `AmanogawaWeb.Params.EventsQuery` (`lib/amanogawa_web/params/events_query.ex`).
  Toutes les bornes sont verifiees cote serveur ; un parametre invalide
  renvoie `{:error, errors}`, jamais une exception.
- Un controleur mince : il parse via le module de params, renvoie 400 en cas
  d'erreur, sinon delegue a la facade du contexte. Aucune logique de requete
  dans le controleur.
- Le module de requetes du contexte centralise les fragments SQL et PostGIS
  (`Amanogawa.Atlas.EventQueries`). Le contexte est le seul a toucher `Repo`.
- Le pipeline `:api` porte le plug de rate limiting
  `AmanogawaWeb.Plugs.RateLimit` (`lib/amanogawa_web/plugs/rate_limit.ex`,
  Hammer par IP).

### Nouvel appel a un service externe

Behaviour + adaptateur Req + Mox + fixtures.
Exemple de reference : `Amanogawa.Ingestion.SparqlClient`.

- Definir un behaviour dans le domaine
  (`lib/amanogawa/ingestion/sparql_client.ex`) : c'est la frontiere
  hexagonale. Les consommateurs dependent du behaviour, jamais d'un
  adaptateur concret.
- Ecrire l'adaptateur de production a cote (`sparql_client/qlever.ex`), avec
  Req pour le HTTP (jamais httpoison ni tesla). L'adaptateur ne laisse
  jamais fuir de detail de transport (statut HTTP, forme JSON brute) : il
  retourne un struct de domaine ou une erreur taguee.
- Resoudre l'adaptateur au runtime par
  `Application.get_env(:amanogawa, :sparql_client)`.
- Declarer le mock Mox dans `test/support/mocks.ex`
  (`Amanogawa.Ingestion.SparqlClientMock`) et enregistrer des fixtures de
  reponses reelles sous `test/support/fixtures/`. Aucun appel reseau en test.

### Travail asynchrone ou en arriere-plan

Un worker Oban, jamais un GenServer artisanal avec timer (loi de fer :
`OBAN FOR BACKGROUND JOBS, NOT GENSERVER`).
Exemple de reference : `Amanogawa.Ingestion.Workers.ImportEvents`
(`lib/amanogawa/ingestion/workers/import_events.ex`), dont toute
l'orchestration de pagination generique vit dans
`Amanogawa.Ingestion.Workers.PagedImport`. Un worker d'ingestion ecrit
toujours par la facade Atlas (`Amanogawa.Atlas.upsert_events/1`), jamais
directement dans les schemas ni dans `Repo`.

### Nouveau rendu carte ou frise

Module de layers cote Elixir + hook JS vanilla + tokens CSS.

- La logique d'etat et de donnees reste cote LiveView et contexte ; le hook
  possede le rendu (MapLibre pour la carte, d3 pour la frise). Un hook par
  responsabilite : `MapHook`, `TimelineHook`, sous `assets/js/hooks/`,
  enregistres dans `assets/js/app.js`.
- Les gros volumes (GeoJSON d'evenements, polygones de frontieres) transitent
  par des endpoints JSON dedies appeles par le hook, PAS par les diffs
  LiveView.
- Les couleurs partagees passent par des tokens CSS (`--time-start-color`,
  etc.) dans `assets/css/app.css`, avec une convention d'interpolation unique
  (`assets/js/lib/time_gradient.js`) consommee par la carte, la frise et la
  legende.
- Un hook nettoie ses ressources dans `destroyed()` (instances de carte,
  observers, listeners).

### Regle des bounded contexts

Un contexte n'expose qu'un seul module public (sa facade). Les modules
internes (schemas, queries, services) sont prives au contexte : on ne les
appelle **jamais** depuis un autre contexte ni depuis la couche web. Un
besoin transverse passe par la facade, meme si cela parait indirect. Si deux
contextes se parlent constamment, on questionne la frontiere et on documente
la decision dans un ADR.

## 4. Regles absolues a ne jamais violer

Resume actionnable des meta-regles et des lois de fer (`CLAUDE.md`,
`.claude/rules/`). Chacune est un absolu, pas une suggestion.

- `mix precommit` vert avant chaque commit : zero erreur, zero avertissement.
- **Aucune requete DB dans `mount/3`** : assigner des valeurs par defaut,
  charger dans `handle_params/3` ou en async (`assign_async` / `start_async`).
- **Jamais de date brute** : toujours annee (entier signe, convention
  astronomique) + precision (echelle Wikidata 0-11), plus le calendrier
  quand il compte. Le type PostgreSQL `date` ne peut pas porter une annee
  prehistorique.
- **SRID 4326 partout** : types PostGIS en base, GeoJSON uniquement au bord
  web, `ST_MakeEnvelope(..., 4326)` explicite.
- **Verifier les permissions avant chaque action** (phase 2 : toute mutation
  de contribution exige un controle d'appartenance ou de droit avant d'agir).
- **Zero tracking, zero analytics tiers, CSP stricte** : MapLibre et d3 sont
  vendorises par le pipeline d'assets, jamais via CDN.
- **Pas de tiret cadratin ni demi-cadratin** nulle part : code, docs,
  commits, chaines d'interface. Preferer virgule, deux-points, parentheses.
- **Aucune reference a un outillage d'assistance** dans le code, les docs,
  les commentaires ou les commits. Si on en trouve une, regle du boy-scout :
  la supprimer immediatement, meme hors scope.
- **Langue** : code, messages de commit et docs de code en anglais ; docs
  strategiques (ADR, features, roadmap) en francais ; contenu utilisateur en
  francais et anglais via Gettext.
- Req pour le HTTP, pas de framework Ash, bibliotheque standard d'abord.
- Attribution des sources : extraits Wikipedia en CC BY-SA 4.0, Cliopatria en
  CC BY 4.0 ; etiquette API Wikimedia (User-Agent identifie, cache, quotas).

## 5. Pieges connus (lecons reelles du projet)

Documentes dans `.claude/memory/tech-stack.md`, retrouves a la livraison.
Les eviter fait gagner des heures.

- **MapLibre rejette les couleurs `oklch()`.** Son parseur de couleurs ne les
  connait pas et refuse silencieusement la couche entiere (evenement `error`
  de la carte, pas d'exception). Toujours resoudre les tokens CSS en `rgb()`
  avant de les passer a MapLibre (voir `maplibreColor` dans le MapHook et
  `time_gradient.js`).
- **Le CSS non layerise de MapLibre bat les utilitaires Tailwind v4.** La
  feuille MapLibre importee sans layer force `position: relative` sur
  `.maplibregl-map` et ecrase tout `absolute`. Dimensionner `#map` avec
  `h-full w-full`, jamais par positionnement absolu.
- **Attributs booleens en HEEx.** `data-x={true}` rend un attribut nu (valeur
  `""`). Pour un temoin relu en JS via `dataset.x === "true"`, rendre
  explicitement `{cond && "true"}`.
- **Un `put_env` de configuration sous test `async: true` cree des courses.**
  Un test qui mute une cle de config partagee (rate limit, notifier, ...) doit
  tourner en `async: false`, ou epuiser une cle qui lui est propre (IP ou
  auteur unique) plutot que muter la config globale. Voir les commentaires de
  `config/test.exs` autour de `AmanogawaWeb.RateLimit` et
  `Amanogawa.Contributions.ProposalThrottle`.
- **Ne jamais muter le niveau du Logger global sous un test async.** Meme
  raison : la mutation fuit vers les tests concurrents.

## 6. Exemple fil rouge

Ajouter un champ `confidence` (niveau de confiance de la datation) a un
evenement, de l'issue au test. Il illustre le patron "nouveau champ de
domaine".

1. **Documentation.** Dans le dossier de la feature concernee, ajouter une
   issue depuis le template : `docs/features/NNN-slug/0XX-champ-confidence.md`,
   titre `# Issue #0YY -- Champ confidence sur l'evenement`. Contexte, user
   story ("En tant que lecteur, je veux voir le niveau de confiance d'une
   datation afin de juger sa fiabilite"), taches, tests a ecrire.

2. **Branche.** `git switch -c feature/NNN-slug` (ou l'issue rejoint une
   feature existante deja en cours).

3. **Migration.** Sous `priv/repo/migrations/`, ajouter la colonne au schema
   `atlas` :

   ```elixir
   alter table(:events, prefix: "atlas") do
     add :confidence, :string
   end
   ```

4. **Schema et changeset.** Dans `lib/amanogawa/atlas/event.ex`, ajouter le
   champ, puis le valider dans `changeset/2`
   (`validate_inclusion(:confidence, ~w(high medium low))`).

5. **Facade et requetes.** Exposer le champ dans la sortie GeoJSON via
   `Amanogawa.Atlas.list_events_geojson/1` (facade) et le module de requetes
   `Amanogawa.Atlas.EventQueries`. Aucun `Repo` hors du contexte Atlas.

6. **Tests.** Ajouter le champ au constructeur canonique
   `Amanogawa.AtlasFixtures.event_fixture/1`
   (`test/support/fixtures/atlas_fixtures.ex`), puis :
   - test DataCase : un evenement avec `confidence: "low"` est retrouve avec
     la propriete dans son GeoJSON ;
   - test de changeset : une valeur hors liste est rejetee (cas d'erreur) ;
   - doctest si une fonction pure de formatage est ajoutee.
   Voir [testing.md](testing.md) pour ecrire chaque type de test.

7. **Boucler.** `mix precommit` vert, commit
   `feat(atlas): add confidence field to events`, PR, revue, merge.
