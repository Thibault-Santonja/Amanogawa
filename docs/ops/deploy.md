# Déploiement (issue #026)

Procédure d'exploitation pour déployer et faire fonctionner Amanogawa sur un VPS avec Docker et Kamal 2. Ce document est la référence pour l'auto-hébergement (ADR 0008, AGPL-3.0) : le Dockerfile et `config/deploy.yml` restent génériques, toute valeur spécifique à un déploiement particulier est un PLACEHOLDER listé ci-dessous.

Aucune valeur de ce dépôt n'a été déployée sur un serveur réel au moment de la rédaction de ce document : le Dockerfile a été construit et exécuté localement (voir "Vérification locale" plus bas), mais aucune connexion SSH ni aucun `kamal setup`/`kamal deploy` n'ont été tentés faute de serveur cible.

## Placeholders à remplacer avant un déploiement réel

| Fichier | Placeholder | À remplacer par |
|---|---|---|
| `config/deploy.yml` | `image: ghcr.io/PLACEHOLDER_GITHUB_USER/amanogawa` | Le compte et le nom du registre réellement utilisés |
| `config/deploy.yml` | `servers.web: [PLACEHOLDER_VPS_HOST_OR_IP]` | L'adresse IP ou le nom d'hôte du VPS |
| `config/deploy.yml` | `proxy.host: amanogawa.example` | Le nom de domaine public de l'application |
| `config/deploy.yml` | `env.clear.PHX_HOST: amanogawa.example` | Le même nom de domaine que `proxy.host` |
| `config/deploy.yml` | `registry.username: PLACEHOLDER_GITHUB_USER` | Le compte propriétaire de l'image |
| `config/deploy.yml` | `accessories.db.host: PLACEHOLDER_VPS_HOST_OR_IP` | Le même VPS que `servers.web` (accessory colocalisé) |
| `config/deploy.yml` | `env.clear.TRUSTED_PROXIES: "172.18.0.0/16"` | Le sous-réseau du réseau Docker privé Kamal sur le VPS (`docker network inspect kamal` après `kamal setup`) : seules les requêtes relayées par kamal-proxy depuis ce sous-réseau sont autorisées à poser `X-Forwarded-For` |
| `.kamal/secrets` (à créer, jamais commité) | toutes les valeurs | Voir `.kamal/secrets.example` (registre, `SECRET_KEY_BASE`, `DATABASE_URL`, `POSTGRES_PASSWORD`, `RELEASE_COOKIE`) |
| DNS | - | Un enregistrement A/AAAA pointant `proxy.host` vers le VPS |

## Prérequis

- Docker installé localement (pour construire et tester l'image) et sur le VPS.
- [Kamal 2](https://kamal-deploy.org) installé localement (`gem install kamal`).
- Un accès SSH au VPS avec une clé autorisée.
- Un compte sur un registre d'images Docker (ghcr.io par défaut dans `config/deploy.yml`).
- Un VPS Hetzner (ou équivalent) avec Docker installé, joignable en SSH.

## Premier déploiement

```sh
# 1. Remplacer tous les placeholders du tableau ci-dessus.
# 2. Créer .kamal/secrets à partir de .kamal/secrets.example (jamais commité).
cp .kamal/secrets.example .kamal/secrets
chmod 600 .kamal/secrets
# ... éditer .kamal/secrets avec les vraies valeurs ...

# 3. Provisionner le serveur (installe Docker si absent, crée le réseau
#    privé Kamal, démarre l'accessory PostgreSQL).
kamal setup
```

`kamal setup` construit l'image, la pousse sur le registre, démarre l'accessory `db` puis le service `amanogawa` ; les migrations tournent automatiquement au démarrage du conteneur (`rel/overlays/bin/docker-entrypoint`, voir "Migrations" plus bas).

## Rôle PostgreSQL dédié (non superuser)

L'application ne se connecte jamais avec le superuser `postgres` de l'accessory : `DATABASE_URL` utilise un rôle dédié, propriétaire de sa seule base. À créer une fois, après le premier `kamal accessory boot db` (ou pendant `kamal setup`, avant le premier démarrage de l'application) :

```sh
kamal accessory exec db --interactive "psql -U postgres"
```

```sql
-- Rôle applicatif : LOGIN seulement, ni SUPERUSER, ni CREATEDB, ni CREATEROLE.
CREATE ROLE amanogawa LOGIN PASSWORD '<mot de passe du rôle, distinct de POSTGRES_PASSWORD>';

-- Propriétaire de sa base uniquement : les migrations créent les schémas
-- atlas/ingestion et leurs tables, ce qui exige la propriété de la base
-- (ou GRANT CREATE), rien de plus. La propriété couvre aussi le schéma
-- public (pg_database_owner), où vivent les tables Oban.
ALTER DATABASE amanogawa_prod OWNER TO amanogawa;
```

Notes :

- L'extension PostGIS est déjà installée dans `amanogawa_prod` par les scripts d'initialisation de l'image `postgis/postgis` : le `CREATE EXTENSION IF NOT EXISTS postgis` de la première migration est alors un no-op qui ne réclame aucun privilège superuser.
- `POSTGRES_PASSWORD` (superuser) ne sert plus qu'à l'administration : création de ce rôle, `psql` d'exploitation, sauvegardes (`docs/ops/restore.md`).
- `DATABASE_URL` devient `ecto://amanogawa:<mot de passe du rôle>@amanogawa-db:5432/amanogawa_prod` (voir `.kamal/secrets.example`).

## Déploiement courant

```sh
kamal deploy
```

Construit une nouvelle image, la pousse, puis effectue un rolling deploy : le nouveau conteneur démarre, passe ses migrations, et n'est basculé en trafic par kamal-proxy qu'une fois son `healthcheck` (`GET /health`) au vert. L'ancien conteneur continue de servir jusqu'à ce bascule, puis est arrêté.

## Zéro interruption de service

Trois éléments fonctionnent ensemble (aucun ne suffit seul) :

1. **Le healthcheck `/health`** (`config/deploy.yml`, `proxy.healthcheck`) : kamal-proxy ne route jamais de trafic vers un conteneur qui n'y répond pas `200`.
2. **Les migrations rétrocompatibles** : chaque migration doit rester compatible avec la version de code N-1, puisque l'ancien conteneur continue de lire/écrire dans la même base pendant la bascule (pattern expand/contract pour toute modification destructive : ajouter la nouvelle colonne dans un déploiement, migrer les données, ne retirer l'ancienne colonne qu'un déploiement ultérieur).
3. **Le verrou de migration** (`Ecto.Migrator`, `lib/amanogawa/release.ex`) : si deux conteneurs démarrent presque simultanément (le nouveau pendant que l'ancien tourne encore), le second `migrate/0` attend que le premier ait terminé plutôt que de courir en parallèle.

## Migrations

`rel/overlays/bin/docker-entrypoint` exécute `Amanogawa.Release.migrate()` avant `bin/amanogawa start`, à **chaque** démarrage de conteneur (`kamal setup`, `kamal deploy`, un simple redémarrage). Pour migrer manuellement sans redémarrer l'application :

```sh
kamal app exec "bin/migrate"
```

Pour revenir en arrière sur une migration précise (à utiliser avec prudence, jamais automatique) :

```sh
kamal app exec -i "bin/amanogawa remote"
# puis dans la console distante :
Amanogawa.Release.rollback(Amanogawa.Repo, 20260101000000)
```

## Rollback applicatif

```sh
kamal rollback
```

Redéploie l'image précédente. Ne modifie pas le schéma de base : si le rollback applicatif suit une migration destructive, une restauration de sauvegarde peut être nécessaire (`docs/ops/restore.md`).

## Consulter les logs

```sh
kamal app logs
kamal app logs -f          # suivi en continu
kamal app logs --grep ERROR
```

En production, chaque ligne est un objet JSON (`Amanogawa.Logging.JSONFormatter`, issue #028) : horodatage ISO 8601 UTC, niveau, message, `request_id` quand disponible. Filtrage avec `jq` :

```sh
kamal app logs | jq 'select(.level == "error")'
kamal app logs | jq 'select(.request_id == "<id>")'
```

**Rétention** : Docker applique par défaut la rotation `json-file` de son daemon ; sur le VPS, elle est bornée (`/etc/docker/daemon.json`, `max-size`/`max-file`) à une taille cohérente avec la politique de confidentialité publiée (`/confidentialite`, issue #027) : les journaux techniques sont conservés pour une durée courte, jamais indéfiniment. Une configuration de départ raisonnable :

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" }
}
```

Alternative sans toucher au daemon (utile sur un VPS mutualisé où `/etc/docker/daemon.json` affecterait les autres projets) : Kamal sait déclarer la même rotation au niveau du conteneur, dans `config/deploy.yml` :

```yaml
logging:
  driver: json-file
  options:
    max-size: 10m
    max-file: 5
```

## Console distante

```sh
kamal app exec -i "bin/amanogawa remote"
```

Ouvre une console IEx connectée au nœud en production. À utiliser avec prudence (accès complet au système, y compris la base de données) ; jamais pour une modification de données ponctuelle qui devrait plutôt passer par une migration ou un script versionné.

## Gestion des secrets

- `.kamal/secrets` (jamais commité, voir `.gitignore` : `/.kamal/secrets*` couvre aussi les fichiers par destination comme `secrets.production`) contient `KAMAL_REGISTRY_PASSWORD`, `SECRET_KEY_BASE`, `DATABASE_URL`, `POSTGRES_PASSWORD`, `RELEASE_COOKIE`. `.kamal/secrets.example` documente chaque variable sans valeur réelle.
- `RELEASE_COOKIE` (cookie de distribution Erlang) est injecté à l'exécution plutôt que figé dans l'image au `mix release` : l'image publiée sur le registre ne contient ainsi jamais de cookie utilisable. Il est requis par la console distante (`bin/amanogawa remote` ci-dessus) ; le générer une fois avec `openssl rand -hex 32` et le conserver stable entre déploiements.
- Kamal injecte chaque secret comme variable d'environnement du conteneur correspondant (`env.secret` dans `config/deploy.yml`) ; `config/runtime.exs` les lit exactement comme dans n'importe quel déploiement Docker classique.
- Aucun secret n'est jamais présent dans `config/deploy.yml`, le Dockerfile, ou l'image construite.

## Alerting (issue #028)

Variables d'environnement optionnelles (`config/runtime.exs`), sans service tiers de tracking :

| Variable | Rôle | Défaut |
|---|---|---|
| `ALERT_RECIPIENT_EMAIL` | Destinataire des alertes. Aucune valeur = alerting désactivé (aucun mail n'est jamais tenté). | (vide) |
| `ALERT_FROM_EMAIL` | Adresse d'expédition. | (vide) |
| `ALERT_ERROR_THRESHOLD` | Nombre d'erreurs déclenchant un mail. | `10` |
| `ALERT_WINDOW_MINUTES` | Fenêtre glissante de comptage. | `5` |
| `ALERT_SILENCE_MINUTES` | Délai minimal entre deux mails. | `60` |
| `SMTP_RELAY_HOST` / `SMTP_RELAY_PORT` | Relais SMTP local du VPS. | `localhost` / `25` |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Authentification optionnelle du relais. | (vide, pas d'authentification) |

## Checklist de smoke test post-déploiement

- [ ] `curl -s https://<domaine>/health` répond le corps `{"status":"ok","version":"..."}` (un `-I`/HEAD ne montrerait pas le corps ; pour le seul code : `curl -s -o /dev/null -w '%{http_code}' https://<domaine>/health` répond `200`).
- [ ] La page d'accueil (`https://<domaine>/`) s'affiche, la carte se charge.
- [ ] Le certificat TLS est valide (émis par Let's Encrypt via kamal-proxy) : `curl -v https://<domaine>/ 2>&1 | grep -i "SSL certificate verify ok"` ou vérification navigateur.
- [ ] `kamal deploy` d'une version N+1 ne produit aucune requête en erreur pendant la bascule (observer `kamal app logs -f` pendant le déploiement).
- [ ] `/sources`, `/mentions-legales`, `/confidentialite` répondent `200`.
- [ ] `TRUSTED_PROXIES` est effectif : depuis deux adresses IP clientes distinctes (par exemple une connexion fixe et une connexion mobile), épuiser le quota `/api/events` de l'une (`429` au-delà de `RATE_LIMIT_PER_MINUTE`) ne doit pas affecter l'autre. Si les deux partagent le même quota, la limitation par IP s'appuie sur l'adresse du proxy au lieu de celle du client : corriger le sous-réseau `TRUSTED_PROXIES` (`docker network inspect kamal`).
- [ ] À J+1 : un dump valide est présent sur le stockage distant (`docs/ops/restore.md`, section sauvegardes).

## Vérification locale (menée pendant l'implémentation de cette issue)

Aucun serveur réel n'existe encore ; l'image a été construite et exécutée en local pour valider le Dockerfile de bout en bout, contre le PostGIS du `docker-compose.yml` du dépôt :

```sh
export POSTGRES_PORT=5433
docker compose up -d --wait

docker build -t amanogawa:test .

# La base applicative n'existe pas encore dans le conteneur PostGIS de dev
# (seules amanogawa_dev/amanogawa_test le sont) : la créer une fois avant
# le premier `docker run`.
docker exec amanogawa-db-1 psql -U postgres \
  -c "CREATE DATABASE amanogawa_prod TEMPLATE template_postgis;"

SECRET_KEY_BASE=$(mix phx.gen.secret)

docker run --rm -d --name amanogawa-test \
  --network amanogawa_default \
  -p 127.0.0.1:4100:4000 \
  -e DATABASE_URL="ecto://postgres:postgres@db:5432/amanogawa_prod" \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e PHX_HOST="localhost" \
  amanogawa:test

curl -s http://127.0.0.1:4100/health
# => {"status":"ok","version":"0.1.0"}
```

Résultat observé : construction de l'image réussie (multi-stage, environ 75s à froid sur Apple Silicon avec émulation `linux/amd64` du builder `hexpm/elixir`, l'image finale démarre en environ 1s), migrations exécutées automatiquement par `rel/overlays/bin/docker-entrypoint`, `GET /health` répond `200` avec `{"status":"ok","version":"0.1.0"}`, `GET /` répond `200` et pose le cookie de session strictement nécessaire à la connexion LiveView (voir `/confidentialite`), `GET /sources` répond `200` sans cookie.
