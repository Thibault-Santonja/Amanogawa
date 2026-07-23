# Issue #002 -- Outillage qualité et alias precommit

**Feature :** F01 -- Fondations
**Priorité :** Haute
**Estimation :** 6h
**Prérequis :** #001

---

## Contexte

La qualité est une contrainte absolue du projet : `mix precommit` doit passer avant chaque commit (CLAUDE.md, AGENTS.md), la couverture doit dépasser 90 % par module (`.claude/rules/testing.md`), et l'analyse statique (Credo strict, Sobelow) fait partie du contrat. Cette issue installe et configure tout l'outillage qualité sur le squelette généré en #001, avant qu'une seule ligne de code métier ne soit écrite : c'est le moment où le coût d'adoption est nul.

Elle prépare aussi les outils de test qui seront exigés dès F02 : Mox (mocks de behaviours pour les adaptateurs Wikidata/Wikipedia, voir `.claude/rules/architecture.md`) et StreamData (property tests obligatoires sur le modèle temporel).

Impact : l'alias `mix precommit` défini ici est exactement celui que la CI (#003) exécutera. Toute divergence entre le local et la CI est interdite.

## User Story

> En tant que développeur, je veux une commande unique `mix precommit` qui compile sans warning, vérifie le formatage, l'analyse statique et la sécurité, et lance les tests, afin de garantir la même barre de qualité en local et en CI.

---

## Tâches

- [ ] Ajouter les dépendances dans `mix.exs` (versions `~>` à vérifier au moment de l'implémentation) :
  - `{:credo, "~> 1.7", only: [:dev, :test], runtime: false}`
  - `{:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}`
  - `{:excoveralls, "~> 0.18", only: :test}`
  - `{:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}`
  - `{:stream_data, "~> 1.1", only: [:dev, :test]}`
  - `{:mox, "~> 1.2", only: :test}`
- [ ] Générer `.credo.exs` avec `mix credo gen.config`, activer le mode strict (`strict: true`) et ajuster : inclure `lib/`, `test/`, exclure `deps/`, `_build/`, `assets/` ; activer les checks de lisibilité et de conception pertinents, documenter en commentaire toute désactivation.
- [ ] Vérifier que `mix sobelow --exit` passe sur le squelette ; si de faux positifs apparaissent sur du code généré, les ignorer via la configuration Sobelow (`.sobelow-conf` généré par `mix sobelow --save-config`) avec un commentaire justifiant chaque exclusion.
- [ ] Configurer excoveralls : dans `mix.exs`, `test_coverage: [tool: ExCoveralls]` et `preferred_cli_env` pour `coveralls`, `coveralls.detail`, `coveralls.html`, `coveralls.json` ; créer `coveralls.json` à la racine avec `"minimum_coverage": 90` et `skip_files` limité au strict boilerplate non testable (par exemple `test/support/`, `lib/amanogawa/application.ex`) ; chaque exclusion doit être justifiée en commentaire de PR.
- [ ] Vérifier que `mix deps.audit` (mix_audit) passe ; il sera branché en CI par #003 et reste exécutable à la demande en local.
- [ ] Définir l'alias `precommit` dans `mix.exs`, dans cet ordre exact :
  1. `compile --warnings-as-errors`
  2. `format --check-formatted`
  3. `credo --strict`
  4. `sobelow --exit`
  5. `test`
- [ ] Vérifier que `mix precommit` passe sur l'arbre propre issu de #001 (corriger tout warning ou écart de formatage du code généré, règle des vitres cassées).
- [ ] Documenter dans le `README.md` une section Qualité : rôle de chaque outil, commande `mix precommit`, commande de couverture (`mix coveralls.html`), commande `mix deps.audit`, seuil de 90 %.

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `mix precommit` passe sur l'arbre propre (vérifié en local et, dès #003, à chaque push).
- [ ] **Edge case** : un fichier volontairement mal formaté fait échouer `mix format --check-formatted` donc `mix precommit` (vérification manuelle documentée dans la PR, fichier retiré ensuite).
- [ ] **Error case** : un warning de compilation introduit volontairement (variable inutilisée) fait échouer `compile --warnings-as-errors` (vérification manuelle documentée dans la PR).
- [ ] **Limit case** : `mix coveralls` échoue si la couverture passe sous 90 % (vérifiable en excluant temporairement un fichier de test) et passe au seuil atteint (vérification manuelle documentée dans la PR).

### Property-based tests (si applicable)

- [ ] Non applicable ici : StreamData est installé et compilé, mais les premières propriétés obligatoires portent sur le modèle temporel (F02). Aucun test artificiel de démonstration.

### Doctests (si applicable)

- [ ] Non applicable : aucune fonction publique ajoutée.

### Tests d'intégration

- [ ] **Intégration** : la suite `mix test` existante (tests de #001) passe sous excoveralls (`mix coveralls`) avec le seuil de 90 %, preuve que la configuration de couverture n'exclut pas abusivement de fichiers.

### Tests end-to-end (si applicable)

- [ ] Non applicable.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `mix.exs` (dépendances, `test_coverage`, `preferred_cli_env`, alias `precommit`)
  - `.credo.exs` (créer)
  - `coveralls.json` (créer)
  - `.sobelow-conf` (créer uniquement si des exclusions justifiées sont nécessaires)
  - `README.md` (section Qualité)
- **Documentation de référence** : CLAUDE.md (méta-règle 1, checklist pre-commit), `.claude/rules/testing.md` (seuil 90 %, types de tests), hexdocs de credo, sobelow, excoveralls, mix_audit, stream_data, mox.
- **Compétences requises** : configuration Mix (aliases, `preferred_cli_env`), lecture des rapports Credo/Sobelow, fonctionnement d'excoveralls.
- **Points d'attention** :
  - L'ordre de l'alias est contractuel : compile d'abord (échec rapide), tests en dernier.
  - Ne pas ajouter `deps.audit` à l'alias `precommit` : la vue d'ensemble F01 le place dans l'outillage (exécution locale à la demande et en CI via #003), le precommit reste rapide et hors réseau.
  - `skip_files` de coveralls est une dette : le garder minimal, jamais de module métier dedans.
  - Aucun behaviour ni mock n'est défini ici : Mox est seulement installé, les behaviours arrivent avec les adaptateurs d'ingestion (F02).
  - Boyscout Rule : tout écart du code généré (warning, format, credo) se corrige dans cette issue, pas plus tard.
