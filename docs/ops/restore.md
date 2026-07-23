# Sauvegardes et restauration PostgreSQL (issue #028)

## Décision : mécanisme de sauvegarde (option A)

**Option A retenue** : cron sur le VPS exécutant `docker exec` sur l'accessory PostgreSQL (`ops/backup/pg_backup.sh`), plutôt qu'un accessory Kamal dédié embarquant son propre cron (option B).

Justification :

- **Simplicité d'exploitation** : un script shell et une ligne de crontab, rien à déployer ni à mettre à jour indépendamment de l'application.
- **Surface de maintenance minimale** : aucune image Docker supplémentaire à construire, publier ou maintenir à jour (sécurité, versions de base) ; l'option B ajouterait un accessory de plus dans `config/deploy.yml` pour un gain marginal.
- **Cohérence avec les autres projets du même VPS mutualisé** (`.claude/memory/tech-stack.md`) : le cron système est déjà le mécanisme standard utilisé ailleurs sur cet hôte.
- Le script ne dépend que d'outils déjà présents sur un VPS Docker standard (`docker`, `pg_dump`/`pg_restore` *à l'intérieur* de l'accessory, pas sur l'hôte) plus `rclone` (une seule installation, un seul binaire statique) et `msmtp` (déjà en place pour les autres projets, ADR 0008/`.claude/rules/ethics.md` : pas de service tiers).

Alternative écartée (**option B**, accessory Kamal dédié) : rejetée, coût d'infrastructure et de maintenance (image à construire, secrets à dupliquer dans `config/deploy.yml`) non justifié pour un cron quotidien.

## Où vivent les sauvegardes

- **Locales, temporaires** : `/var/backups/amanogawa/` sur le VPS pendant la durée du transfert seulement ; `ops/backup/pg_backup.sh` supprime le fichier local après un envoi distant réussi. Le VPS n'est jamais le stockage de référence.
- **Distantes, durables** : un stockage séparé du VPS (Hetzner Storage Box ou tout remote compatible `rclone`), configuré via `RCLONE_REMOTE` dans le fichier d'environnement du script (`/etc/amanogawa/backup.env`, permissions 600, jamais commité). Une panne ou une compromission du VPS n'emporte donc jamais les sauvegardes existantes. Recommandé : un jeton d'écriture pour le cron (pas de suppression), la rotation elle-même s'exécutant avec des identifiants distincts si le fournisseur le permet (`.claude/rules/pragmatic-developer.md`'s own "résister à une compromission").
- **Nommage** : `amanogawa_YYYY-MM-DD.dump`, préfixe `amanogawa_` pour éviter toute collision avec les sauvegardes d'autres projets sur le même stockage mutualisé. Un dump par jour UTC, nom déterministe : relancer le script le même jour **écrase** le dump du jour, en local comme sur le remote (`rclone copyto` remplace la destination). Comportement assumé : le cron quotidien est idempotent, et une relance manuelle après un échec répare la sauvegarde du jour au lieu d'empiler des variantes.
- **Permissions** : le script pose `umask 077` et crée le répertoire local en `700` (`install -d -m 700`) ; le dump n'est jamais lisible au-delà de son propriétaire, même pendant le transfert.
- **Chiffrement du remote** : le transport vers une Storage Box Hetzner passe par SFTP (backend `sftp` de rclone : identifiants et transfert chiffrés). Pour un chiffrement au repos indépendant du fournisseur, envelopper le remote dans un backend [`rclone crypt`](https://rclone.org/crypt/) (`rclone config`, type `crypt`, pointant le remote SFTP ; `RCLONE_REMOTE` référence alors le remote chiffré). Recommandé dès que le stockage distant est mutualisé ou géré par un tiers ; conserver la passphrase `crypt` hors du VPS (gestionnaire de mots de passe), sans elle les sauvegardes sont irrécupérables.

## Rotation

7 quotidiennes + 4 hebdomadaires + 6 mensuelles, appliquée sur le stockage distant par `ops/backup/rotate_backups.sh` (appelé automatiquement par `pg_backup.sh` après chaque envoi réussi) :

- **Quotidiennes** : les 7 dumps les plus récents, sans condition.
- **Hebdomadaires** : le dump le plus récent de chacune des 4 semaines ISO les plus récentes (au-delà des quotidiennes).
- **Mensuelles** : le dump le plus récent de chacun des 6 derniers mois calendaires.

Un même fichier peut satisfaire plusieurs catégories à la fois (par exemple le dump du jour compte à la fois comme quotidien et comme représentant du mois en cours) : le nombre réel de fichiers conservés est donc inférieur ou égal à 17, jamais garanti égal à ce total (constaté à l'exercice ci-dessous : 14 fichiers conservés sur 200 simulés).

## Configuration (`/etc/amanogawa/backup.env`, permissions 600)

```sh
POSTGRES_CONTAINER=amanogawa-db     # nom du conteneur accessory Kamal
POSTGRES_DB=amanogawa_prod
# Superuser du conteneur : pg_dump s'exécute DANS l'accessory via `docker
# exec` sans mot de passe (auth locale), le superuser est le choix robuste
# ici. Le rôle applicatif dédié `amanogawa` (docs/ops/deploy.md, "Rôle
# PostgreSQL dédié"), propriétaire de la base, fonctionne aussi.
POSTGRES_USER=postgres
RCLONE_REMOTE=hetzner-storagebox:amanogawa/backups
BACKUP_LOCAL_DIR=/var/backups/amanogawa   # optionnel, valeur par défaut

# Alerte d'échec (envoyée par le script lui-même, pas par le mécanisme
# de mail implicite de cron, pour rester indépendant de la configuration
# MAILTO du système) :
BACKUP_ALERT_EMAIL=ops@example.test
BACKUP_ALERT_FROM=amanogawa-backup@example.test
MSMTP_ACCOUNT=default               # optionnel, compte msmtp à utiliser
```

`rclone` doit être configuré séparément (`rclone config`, une fois, avec les identifiants du Storage Box) ; `RCLONE_REMOTE` référence ensuite le nom du remote ainsi créé.

## Installer le cron quotidien

Heure creuse, après les fenêtres d'ingestion mensuelle (`config/config.exs`, `Oban.Plugins.Cron`, 02h00 UTC les 1er/2/3 du mois) pour éviter toute contention :

```cron
# /etc/cron.d/amanogawa-backup
0 4 * * * root AMANOGAWA_BACKUP_ENV_FILE=/etc/amanogawa/backup.env /usr/local/bin/amanogawa_pg_backup.sh >> /var/log/amanogawa/pg_backup.log 2>&1
```

Le script gère lui-même la remontée d'échec par mail (`notify_failure`, `ops/backup/pg_backup.sh`) : toute sortie avec un code non nul, quelle qu'en soit la cause (`set -Eeuo pipefail` pour les commandes non vérifiées, chemins `die` explicites compris), passe par le `trap 'on_exit $?' EXIT`, qui supprime l'éventuel dump local partiel puis envoie un mail via le relais SMTP local (`msmtp`) avant de propager le code de sortie. Un `trap ERR` seul ne couvrirait pas les chemins `die` (un `exit 1` explicite ne déclenche pas ERR). Le fichier de log (`>> ... 2>&1`) reste la source de diagnostic détaillé ; le mail ne contient qu'un résumé (code de sortie).

## Vérification `--dry-run`

`ops/backup/pg_backup.sh` n'a pas d'option `--dry-run` dédiée : chaque étape est elle-même une vérification (`pg_restore --list` sur le dump avant tout envoi, taille du fichier distant après l'envoi). La chaîne complète a été exercée manuellement contre la base locale de développement (`docker-compose.yml`), voir "Exercice de restauration" ci-dessous pour le détail et le résultat.

## Procédure de restauration

1. **Récupérer le dump** depuis le stockage distant :

   ```sh
   rclone copy "$RCLONE_REMOTE/amanogawa_YYYY-MM-DD.dump" /tmp/restore/
   ```

2. **Démarrer un conteneur PostGIS vierge** (même image que l'accessory de production, `postgis/postgis:18-3.6`, jamais le conteneur de production lui-même) :

   ```sh
   docker run -d --name amanogawa-restore-drill \
     -e POSTGRES_PASSWORD=<mot de passe temporaire> \
     postgis/postgis:18-3.6
   ```

3. **Créer la base cible** à partir du template PostGIS (l'extension doit exister avant la restauration, `pg_restore` ne la crée pas) :

   ```sh
   docker exec amanogawa-restore-drill psql -U postgres \
     -c "CREATE DATABASE amanogawa_restored TEMPLATE template_postgis;"
   ```

4. **Restaurer** :

   ```sh
   docker cp /tmp/restore/amanogawa_YYYY-MM-DD.dump amanogawa-restore-drill:/tmp/dump
   docker exec amanogawa-restore-drill pg_restore \
     --username=postgres --dbname=amanogawa_restored --no-owner --exit-on-error /tmp/dump
   ```

5. **Vérifications PostGIS et volumétrie** :

   ```sh
   docker exec amanogawa-restore-drill psql -U postgres -d amanogawa_restored \
     -c "\dn" \
     -c "SELECT extname, extversion FROM pg_extension;" \
     -c "SELECT schemaname, tablename FROM pg_tables WHERE schemaname IN ('atlas','ingestion') ORDER BY 1,2;" \
     -c "SELECT count(*) FROM atlas.events;"
   ```

   Attendu : les schémas `atlas`/`ingestion` présents, l'extension `postgis` installée, les cinq tables (`atlas.borders`, `atlas.event_links`, `atlas.events`, `atlas.polities`, `ingestion.sync_runs`), un nombre de lignes cohérent avec la volumétrie connue au moment du dump.

6. **Recréer le rôle applicatif dédié** (l'instance cible est vierge, le dump restauré avec `--no-owner` appartient à `postgres`) puis lui rendre la propriété de la base, comme au premier déploiement (`docs/ops/deploy.md`, "Rôle PostgreSQL dédié") :

   ```sh
   docker exec amanogawa-restore-drill psql -U postgres \
     -c "CREATE ROLE amanogawa LOGIN PASSWORD '<mot de passe du rôle>';" \
     -c "ALTER DATABASE amanogawa_restored OWNER TO amanogawa;"
   docker exec amanogawa-restore-drill psql -U postgres -d amanogawa_restored \
     -c "ALTER SCHEMA atlas OWNER TO amanogawa;" \
     -c "ALTER SCHEMA ingestion OWNER TO amanogawa;"
   # Vérifier avec \dn+ que amanogawa possède bien atlas et ingestion.
   ```

7. **Rebrancher l'application** : pointer `DATABASE_URL` de l'application (avec le rôle `amanogawa`, jamais le superuser) vers la base restaurée (sur un environnement jetable pour un exercice, sur l'accessory réel restauré pour un incident réel), redémarrer le conteneur applicatif.

8. **Smoke test** : `GET /health` répond `200`, la page d'accueil et la carte se chargent, `GET /api/borders?year=<année>` répond `200`.

## Exercice de restauration réel

**Date** : 2026-07-24. **Environnement** : disposable local (Docker Desktop, pas le VPS de production, qui n'existe pas encore à ce stade du projet). **Résultat : réussite complète.**

Déroulé exact :

1. Dump de `amanogawa_dev` (base de développement locale, `docker-compose.yml`) via `docker exec amanogawa-db-1 pg_dump --username=postgres --format=custom --dbname=amanogawa_dev`, en amont exercé aussi via `ops/backup/pg_backup.sh` lui-même (voir ci-dessous) : fichier de 51 Ko, `pg_restore --list` a listé 65 entrées de TOC sans erreur.
2. `ops/backup/pg_backup.sh` exécuté de bout en bout contre la base de développement locale (conteneur `debian:bookworm-slim` jetable avec `docker.io`/`rclone` installés, socket Docker de l'hôte monté, `RCLONE_REMOTE` pointant un dossier local jouant le rôle du stockage distant) : dump, vérification d'intégrité, envoi, vérification de la taille distante, rotation, suppression locale -- toutes les étapes ont réussi (`backup completed successfully`).
3. Un conteneur `postgis/postgis:18-3.6` neuf (`amanogawa-restore-drill`) a été démarré, une base `amanogawa_restored` créée depuis `template_postgis`, puis le dump restauré avec `pg_restore --no-owner --exit-on-error` : code de sortie 0.
4. Vérifications : schémas `atlas`/`ingestion` présents ; extensions `postgis` (3.6.4), `postgis_topology`, `postgis_tiger_geocoder`, `fuzzystrmatch` toutes installées ; les cinq tables attendues présentes ; `atlas.events` contenait 604 lignes, restaurées à l'identique.
5. L'image de production construite pour l'issue #026 (`Dockerfile`) a été démarrée avec `DATABASE_URL` pointant la base restaurée : les migrations se sont rejouées sans erreur (déjà appliquées, `Ecto.Migrator` les a reconnues comme à jour), `GET /health` a répondu `200` avec `{"status":"ok","version":"0.1.0"}`, `GET /api/borders?year=0` a répondu `200` avec une `FeatureCollection` valide.

Corrections apportées à la documentation suite à l'exercice (ce document reflète déjà l'état corrigé) :

- La création de la base cible (`CREATE DATABASE ... TEMPLATE template_postgis`) est une étape à part entière, omise dans une première version de la procédure : `pg_restore` seul ne crée ni la base ni l'extension PostGIS, la restauration échoue silencieusement sur les types géométriques sans cette étape préalable.
- `pg_restore` a besoin de `--no-owner` dans cet exercice : le dump a été produit avec l'utilisateur `postgres` du conteneur source, restaurer sans cette option échoue si l'utilisateur cible diffère (pas le cas ici, mais l'option rend la procédure robuste à un renommage d'utilisateur entre les deux environnements, un cas réaliste en restauration d'urgence).
- `pg_restore --list` doit être invoqué via `docker exec -i <conteneur> pg_restore --list < fichier` (le dump vit sur l'hôte, `pg_restore` vit dans le conteneur) plutôt que d'exiger `pg_restore` sur l'hôte lui-même : évite une dépendance supplémentaire sur la machine qui orchestre la sauvegarde.

### Prochain exercice périodique

À rejouer avant chaque changement significatif du schéma de données (nouvelle extension PostgreSQL, migration destructive) et au minimum une fois par trimestre une fois en production, contre le dernier dump réel du stockage distant plutôt que contre la base de développement. Consigner chaque exécution (date, résultat, corrections) à la suite de celle-ci dans ce document.
