# Issue #028 -- Sauvegardes PostgreSQL et observabilité minimale

**Feature :** F06 -- Déploiement et pages légales
**Priorité :** Haute
**Estimation :** 8h
**Prérequis :** #026

---

## Contexte

Une fois le MVP déployé (#026), la production ne doit pas reposer sur la chance : une base sans sauvegarde testée est une perte de données en attente, et une application sans logs exploitables ni alerte est invisible quand elle casse. Cette issue couvre les trois volets : sauvegardes quotidiennes de PostgreSQL vers un stockage séparé avec rotation, procédure de restauration testée réellement et documentée, logs JSON structurés en production et alerting minimal.

Contrainte éthique structurante (ADR 0008, `.claude/rules/ethics.md`) : aucun service tiers de tracking ou d'APM (pas de Sentry SaaS, pas de Datadog). L'observabilité reste sobre et auto-hébergée : logs JSON exploitables sur le VPS, alerte par mail en cas d'erreurs répétées.

Insertion dans l'architecture : les sauvegardes vivent côté infrastructure (script + cron sur le VPS, ciblant l'accessory PostgreSQL de #026) ; les logs JSON sont une configuration du Logger en production (formatter dédié) ; l'alerting est un handler Logger applicatif qui compte les erreurs et envoie un mail au-delà d'un seuil.

Impact sur le reste du système : le format des logs de production change (JSON), ce que la documentation d'exploitation doit refléter ; la durée de rétention des journaux doit rester cohérente avec la politique de confidentialité publiée en #027 ; le healthcheck `/health` de #026 n'est pas modifié.

## User Story

> En tant que mainteneur du projet, je veux des sauvegardes quotidiennes restaurables et une alerte en cas d'erreurs répétées en production, afin de pouvoir reconstruire le service après un incident et d'être prévenu des pannes sans dépendre d'un service tiers de tracking.

---

## Tâches

- [ ] Trancher et documenter le mécanisme d'exécution des sauvegardes, deux options :
  - **Option A (recommandée)** : cron sur le VPS exécutant `docker exec` sur l'accessory PostgreSQL (`pg_dump`), simple, sans image supplémentaire à maintenir.
  - **Option B** : accessory Kamal dédié embarquant cron + client PostgreSQL.
  - Critères : simplicité d'exploitation, surface de maintenance, cohérence avec les autres projets sur le même VPS. Consigner la décision et sa justification dans `docs/ops/restore.md` (section sauvegardes) et dans `.claude/memory/`.
- [ ] Écrire le script `ops/backup/pg_backup.sh` :
  - `pg_dump --format=custom` de la base de production (schémas `atlas` et `ingestion` inclus), fichier horodaté (`amanogawa_YYYY-MM-DD.dump`).
  - Vérification d'intégrité immédiate : dump non vide et lisible par `pg_restore --list` avant de le considérer valide.
  - Transfert vers un stockage séparé du VPS (Hetzner Storage Box via rclone ou sftp) : une panne ou compromission du VPS ne doit pas emporter les sauvegardes.
  - Rotation sur le stockage distant : conserver 7 quotidiennes, 4 hebdomadaires, 6 mensuelles ; suppression des dumps au-delà.
  - Sortie non nulle et message d'erreur explicite à la moindre étape en échec ; `set -euo pipefail` ; propre au regard de shellcheck.
  - Identifiants (base, stockage distant) lus depuis un fichier d'environnement hors dépôt, permissions 600 ; rien de secret dans le script.
- [ ] Installer le cron quotidien (heure creuse) et sa remontée d'échec : toute exécution en échec déclenche un mail via le relais SMTP local du VPS (msmtp ou équivalent déjà en place pour les autres projets), pas de service tiers.
- [ ] Rédiger `docs/ops/restore.md` : localisation des sauvegardes, procédure de restauration pas à pas (récupérer le dump, démarrer un conteneur postgis vierge, `pg_restore`, vérifications PostGIS et volumétrie, rebrancher l'application, smoke test `/health` et carte), procédure de test périodique.
- [ ] Réaliser un exercice de restauration réel (restore drill) : restaurer le dernier dump dans un environnement jetable, dérouler la procédure documentée, corriger la documentation aux endroits où elle était fausse ou ambiguë, consigner la date et le résultat de l'exercice dans `docs/ops/restore.md`. L'issue n'est pas terminée tant qu'une restauration complète n'a pas réussi.
- [ ] Mettre en place les logs JSON en production :
  - Implémenter un formatter minimal `Amanogawa.Logging.JSONFormatter` (contrat formatter de Logger, sérialisation Jason) plutôt qu'une dépendance supplémentaire (règle : minimiser les bibliothèques externes) ; ne basculer sur `logger_json` que si le formatter maison s'avère réellement plus coûteux, et documenter ce choix.
  - Champs : horodatage ISO 8601 UTC, niveau, message, `request_id` (Plug.RequestId, déjà dans les métadonnées Phoenix), métadonnées utiles ; toute métadonnée non sérialisable est convertie via `inspect/1`, jamais de crash du formatter.
  - Activer le formatter en production uniquement (`config/runtime.exs` ou `config/prod.exs`) ; le format de développement reste inchangé.
  - Documenter dans `docs/ops/deploy.md` la consultation et le filtrage (`kamal app logs` + jq) et la rétention des logs Docker (rotation json-file bornée, cohérente avec la politique de confidentialité de #027).
- [ ] Mettre en place l'alerting minimal, à trancher dans cette issue entre :
  - **Option A (recommandée)** : handler applicatif `Amanogawa.Alerting.ErrorReporter` attaché à Logger, qui compte les événements de niveau `error` sur une fenêtre glissante et envoie un mail quand un seuil est franchi (par exemple 10 erreurs en 5 minutes), avec période de silence (au plus un mail par heure) pour éviter la tempête de mails ; envoi SMTP sobre (Swoosh + gen_smtp vers le relais du VPS ; le mailer n'existe pas encore, F01 a généré le projet sans).
  - **Option B** : script cron sur le VPS analysant les logs JSON Docker et envoyant le mail, zéro code applicatif.
  - Critères : fiabilité (l'option B survit à un crash complet de l'application, l'option A est plus précise), coût en dépendances, testabilité. Consigner la décision et sa justification dans l'issue au moment de l'implémentation et dans `.claude/memory/`.
- [ ] Si l'option A est retenue : seuils et destinataire configurés via l'environnement, envoi derrière un behaviour (testable avec Mox), et garantie que l'alerting ne peut jamais faire tomber l'application (échec d'envoi capturé et loggué, pas de récursion d'erreur).

---

## Tests à écrire

### Tests unitaires

- [ ] **Happy path** : `JSONFormatter` produit une ligne JSON décodable par `Jason.decode!/1` contenant horodatage, niveau, message et `request_id` quand il est présent dans les métadonnées.
- [ ] **Edge case** : métadonnées contenant des termes non sérialisables (pid, référence, struct, charlist, tuple) : la ligne reste du JSON valide, les termes sont rendus via `inspect/1`.
- [ ] **Error case** : message ou métadonnées pathologiques (binaire non UTF-8, terme profondément imbriqué) : le formatter ne lève jamais, il dégrade proprement.
- [ ] **Happy path (alerting, option A)** : N erreurs dans la fenêtre déclenchent exactement un mail (mailer mocké via Mox) avec le compte d'erreurs et la période dans le sujet ou le corps.
- [ ] **Edge case (alerting)** : N-1 erreurs dans la fenêtre ne déclenchent aucun mail ; les erreurs hors fenêtre glissante ne comptent plus.
- [ ] **Error case (alerting)** : l'échec du mailer (Mox simule une exception SMTP) est capturé : pas de crash du handler, pas de boucle (l'erreur d'envoi ne redéclenche pas d'alerte).
- [ ] **Limit case (alerting)** : rafales répétées d'erreurs pendant la période de silence : au plus un mail par période, le compteur repart ensuite.

### Property-based tests (si applicable)

- [ ] **Property** : pour des métadonnées arbitraires générées par StreamData (termes Elixir quelconques, imbrication bornée), la sortie du `JSONFormatter` est toujours décodable par `Jason.decode!/1` (le formatter est un point de passage de données hostiles, comme un parser).

### Doctests (si applicable)

- [ ] Non applicable : formatter et handler dépendent de Logger, pas d'exemple pur pertinent en moduledoc.

### Tests d'intégration

- [ ] **Intégration** : avec le formatter configuré (config de test dédiée ou configuration temporaire du handler), une requête HTTP via `ConnCase` produit des lignes de log JSON valides portant le `request_id` de la réponse (`capture_log`).
- [ ] **Intégration (option A)** : un burst d'erreurs logguées de bout en bout (Logger réel, handler attaché) aboutit à un appel unique au behaviour d'envoi (Mox), prouvant le câblage complet handler + seuil + silence.
- [ ] **Intégration (script)** : shellcheck sur `ops/backup/pg_backup.sh` intégré à la CI ; mode `--dry-run` du script vérifié manuellement contre une base locale et consigné dans `docs/ops/restore.md`.

### Tests end-to-end (si applicable)

- [ ] **E2E** : exercice de restauration réel documenté et daté dans `docs/ops/restore.md` (voir tâches) : c'est le test de vérité de cette issue, non automatisable en CI.
- [ ] **E2E** : vérification post-déploiement que le cron a produit un dump valide sur le stockage distant à J+1, consignée dans la checklist d'exploitation.

---

## Notes pour le développeur

- **Fichiers à créer/modifier** :
  - `ops/backup/pg_backup.sh`
  - `docs/ops/restore.md` (nouveau), `docs/ops/deploy.md` (sections logs et exploitation)
  - `lib/amanogawa/logging/json_formatter.ex`
  - `lib/amanogawa/alerting/error_reporter.ex` et `lib/amanogawa/alerting/notifier.ex` (behaviour d'envoi) si option A
  - `lib/amanogawa/application.ex` (attachement du handler) si option A
  - `config/prod.exs` ou `config/runtime.exs` (formatter, seuils, destinataire), `.env.example`
  - `mix.exs` (Swoosh + gen_smtp uniquement si option A retenue)
  - `.github/workflows/ci.yml` (shellcheck)
  - `test/amanogawa/logging/json_formatter_test.exs`, `test/amanogawa/alerting/error_reporter_test.exs`, `test/support/mocks.ex`
- **Documentation de référence** : issue #026 (accessory PostgreSQL, `docs/ops/deploy.md`), ADR 0008 et `.claude/rules/ethics.md` (zéro service tiers de tracking), `.claude/rules/testing.md` (Mox, pas de `Process.sleep` : piloter la fenêtre glissante par injection d'horloge), documentation PostgreSQL (`pg_dump`, `pg_restore`), documentation Logger (handlers et formatters), Hetzner Storage Box.
- **Compétences requises** : administration PostgreSQL (dump et restore, format custom), shell robuste (`set -euo pipefail`, shellcheck), cron, Logger Erlang/Elixir (handlers, formatters), SMTP basique.
- **Points d'attention** :
  - Une sauvegarde jamais restaurée n'est pas une sauvegarde : l'exercice de restauration fait partie du périmètre, pas de l'après.
  - Le stockage des dumps doit être séparé du VPS ; idéalement, le VPS ne peut pas supprimer les sauvegardes existantes (jeton en écriture seule ou append-only si le stockage le permet), pour résister à une compromission.
  - Les dumps contiennent la base complète : les traiter comme des secrets (transport chiffré, permissions restrictives, pas de copie qui traîne).
  - Le VPS est mutualisé avec d'autres projets : nommer crons, scripts et chemins avec le préfixe `amanogawa` pour éviter toute collision.
  - Pour la fenêtre glissante de l'alerting, injecter l'horloge (fonction ou module de temps passé en paramètre) afin de tester sans `Process.sleep`, conformément à `.claude/rules/testing.md`.
  - Ne pas logger de données sensibles dans les métadonnées JSON (pas d'URL de base avec mot de passe, pas de corps de requête) ; la rétention des logs doit rester cohérente avec la politique de confidentialité publiée en #027.
  - Rester sobre : pas de stack d'observabilité (Prometheus, Grafana, Loki) en phase 1 ; le besoin réel est un mail quand ça casse et des logs lisibles quand on investigue.
