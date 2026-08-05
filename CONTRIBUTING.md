# Contribuer à Amanogawa

Merci de l'intérêt porté au projet. Ce document rassemble l'essentiel pour proposer une contribution. Le détail du parcours (comprendre le code, ajouter une feature, écrire les tests) est dans [`docs/development/`](docs/development/README.md).

Avant d'écrire du code, lire au minimum [`docs/development/getting-started.md`](docs/development/getting-started.md) (mise en route) et [`docs/development/adding-a-feature.md`](docs/development/adding-a-feature.md) (démarche pas à pas).

## Conventions non négociables

Ces règles sont appliquées automatiquement (CI) ou vérifiées en revue. Une contribution qui ne les respecte pas ne peut pas être mergée.

- **`mix precommit` avant chaque commit.** La commande enchaîne compilation sans warning, formatage, Credo strict, Sobelow, build des assets et tous les tests. Elle doit passer. La CI rejoue exactement cette commande, il n'y a aucune divergence à espérer.
- **Tests exigés.** Toute logique nouvelle ou modifiée est couverte. Le seuil de couverture est de 90 % minimum (`mix coveralls`), appliqué en CI.
- **Commits conventionnels.** Format `<type>(<scope>): <sujet>`, sujet à l'impératif, en minuscule, sans point final. Types : `feat`, `fix`, `docs`, `refactor`, `test`, `chore`. Scopes : `atlas`, `ingestion`, `accounts`, `contributions`, `web`, `map`, `timeline`, `infra`, `config`, `deps`.
- **Politique de langue.** Code, messages de commit et documentation technique du code en anglais. Documentation stratégique (ADR, features, roadmap) en français. Contenu destiné à l'utilisateur en français et en anglais (Gettext).
- **Pas de tiret cadratin (`—`) ni demi-cadratin (`–`)**, nulle part : code, docs, commits, chaînes d'interface. Préférer la virgule, les deux-points ou les parenthèses.
- **Ne pas versionner la configuration d'agents.** Les répertoires et fichiers `.claude/`, `CLAUDE.md` et `AGENTS.md` ne doivent jamais être ajoutés au dépôt.

## Principes structurants

- **Chercher avant de créer.** Réutiliser le code existant plutôt qu'ajouter un helper ou une dépendance. Les contextes bornés (Atlas, Ingestion, Accounts, Contributions) ne communiquent que par leur module d'API public, jamais par leurs modules internes.
- **Respecter l'étiquette Wikimedia.** Un seul import à la fois par pipeline, User-Agent identifié, cache, jamais de parallélisation pour aller plus vite (voir [`docs/ops/sync.md`](docs/ops/sync.md)).
- **Attribuer les sources.** Les extraits Wikipedia sont sous CC BY-SA 4.0, les frontières Cliopatria sous CC BY 4.0 : attribution et lien obligatoires.
- **Éthique.** Zéro tracking, zéro analytics tiers, Content-Security-Policy stricte.

## Workflow

1. Ouvrir ou reprendre une issue. Les features et leurs issues sont spécifiées dans [`docs/features/`](docs/features/) ; respecter les prérequis annoncés par chaque issue.
2. Travailler sur une branche dédiée (une branche par feature ou par correctif), jamais directement sur `main`.
3. Écrire le code et les tests, puis lancer `mix precommit` jusqu'à ce qu'il passe.
4. Ouvrir une pull request. La CI doit être verte (quality gate, couverture, E2E, shellcheck, build Docker).
5. La revue vérifie la qualité, la sécurité, la rigueur historique et le respect des conventions ci-dessus.

Pour la marche à suivre complète d'une contribution de bout en bout, voir [`docs/development/adding-a-feature.md`](docs/development/adding-a-feature.md).
</content>
