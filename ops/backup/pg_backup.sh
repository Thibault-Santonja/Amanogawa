#!/usr/bin/env bash
# amanogawa_pg_backup.sh -- daily PostgreSQL backup with remote rotation
# (issue #028).
#
# Runs on the VPS host (option A, docs/ops/restore.md: cron + `docker
# exec` against the PostGIS accessory, no extra image to maintain), never
# inside a container itself. Prefixed `amanogawa_` throughout (temp files,
# log lines, cron entry) since the VPS is mutualized with other projects
# (`.claude/rules/pragmatic-developer.md`'s own naming discipline).
#
# Steps: pg_dump --format=custom -> integrity check (pg_restore --list) ->
# upload to a storage location separate from this VPS (Hetzner Storage Box
# via rclone, or any rclone-compatible remote) -> rotate the remote copies
# (7 daily / 4 weekly / 6 monthly) -> remove the local copy -> on any
# failure, a short mail through the VPS's own local SMTP relay (msmtp).
#
# Configuration lives in an environment file OUTSIDE this repository,
# permissions 600 (never committed, never world-readable: it names the
# database container and holds no secret itself, but the mail relay
# account below might). See docs/ops/restore.md for the exact variables
# and the crontab line that runs this script daily.

set -euo pipefail

readonly SCRIPT_NAME="amanogawa_pg_backup"
readonly ENV_FILE="${AMANOGAWA_BACKUP_ENV_FILE:-/etc/amanogawa/backup.env}"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

# Sent on any failure, whether from an explicit `die` call or from `set
# -e` tripping on an unchecked command (the ERR trap below covers both):
# the whole point of "remontee d'echec" (issue #028) is that a broken
# backup is never silent.
notify_failure() {
  local exit_code=$1
  local line=$2

  if [[ -z "${BACKUP_ALERT_EMAIL:-}" ]]; then
    printf '[%s] ERROR: failed at line %s (exit %s); BACKUP_ALERT_EMAIL not set, no mail sent\n' \
      "$SCRIPT_NAME" "$line" "$exit_code" >&2
    return
  fi

  local subject="Amanogawa: echec de la sauvegarde PostgreSQL"
  local body
  body="$(printf 'La sauvegarde amanogawa_pg_backup.sh a echoue a la ligne %s (code %s).\n\nVoir le journal du cron pour le detail.\n' "$line" "$exit_code")"

  if command -v msmtp >/dev/null 2>&1; then
    {
      printf 'To: %s\n' "$BACKUP_ALERT_EMAIL"
      printf 'From: %s\n' "${BACKUP_ALERT_FROM:-amanogawa-backup@localhost}"
      printf 'Subject: %s\n\n' "$subject"
      printf '%s\n' "$body"
    } | msmtp -a "${MSMTP_ACCOUNT:-default}" "$BACKUP_ALERT_EMAIL" \
      || printf '[%s] ERROR: msmtp itself failed while reporting the backup failure\n' "$SCRIPT_NAME" >&2
  else
    printf '[%s] ERROR: msmtp not found, cannot send the failure mail\n' "$SCRIPT_NAME" >&2
  fi
}

on_err() {
  local exit_code=$?
  notify_failure "$exit_code" "${BASH_LINENO[0]:-unknown}"
  exit "$exit_code"
}

trap on_err ERR

[[ -f "$ENV_FILE" ]] || die "environment file not found: $ENV_FILE"

# The environment file names the database container, the rclone remote,
# and (optionally) the mail relay account: none of that is a secret by
# itself, but 600 permissions are required regardless (defense in depth,
# `.claude/rules/security.md`) since a future addition (a password) must
# not silently become world-readable.
env_perms="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%OLp' "$ENV_FILE")"
[[ "$env_perms" == "600" ]] || die "environment file must be permissions 600, found $env_perms: $ENV_FILE"

# shellcheck source=/dev/null
source "$ENV_FILE"

: "${POSTGRES_CONTAINER:?POSTGRES_CONTAINER is required in $ENV_FILE}"
: "${POSTGRES_DB:?POSTGRES_DB is required in $ENV_FILE}"
: "${POSTGRES_USER:?POSTGRES_USER is required in $ENV_FILE}"
: "${RCLONE_REMOTE:?RCLONE_REMOTE is required in $ENV_FILE, for example hetzner-storagebox:amanogawa/backups}"
BACKUP_LOCAL_DIR="${BACKUP_LOCAL_DIR:-/var/backups/amanogawa}"

DATE="$(date -u +%F)"
readonly DATE
readonly DUMP_NAME="amanogawa_${DATE}.dump"
readonly LOCAL_PATH="${BACKUP_LOCAL_DIR}/${DUMP_NAME}"

mkdir -p "$BACKUP_LOCAL_DIR"

log "dumping database '$POSTGRES_DB' from container '$POSTGRES_CONTAINER' to $LOCAL_PATH"
docker exec "$POSTGRES_CONTAINER" \
  pg_dump --username="$POSTGRES_USER" --format=custom --dbname="$POSTGRES_DB" \
  > "$LOCAL_PATH"

[[ -s "$LOCAL_PATH" ]] || die "dump file is empty: $LOCAL_PATH"

log "verifying dump integrity with pg_restore --list"
docker exec -i "$POSTGRES_CONTAINER" pg_restore --list < "$LOCAL_PATH" > /dev/null \
  || die "pg_restore --list could not read the dump (corrupt or truncated): $LOCAL_PATH"

log "uploading to remote storage: ${RCLONE_REMOTE}/${DUMP_NAME}"
rclone copyto "$LOCAL_PATH" "${RCLONE_REMOTE}/${DUMP_NAME}"

log "confirming the upload landed on the remote"
remote_size="$(rclone size --json "${RCLONE_REMOTE}/${DUMP_NAME}" | grep -o '"bytes":[0-9]*' | cut -d: -f2)"
[[ -n "$remote_size" && "$remote_size" -gt 0 ]] \
  || die "uploaded dump is missing or empty on the remote: ${RCLONE_REMOTE}/${DUMP_NAME}"

log "rotating remote backups (7 daily / 4 weekly / 6 monthly)"
"$(dirname "$0")/rotate_backups.sh" "$RCLONE_REMOTE"

log "removing local copy"
rm -f "$LOCAL_PATH"

log "backup completed successfully: $DUMP_NAME"
