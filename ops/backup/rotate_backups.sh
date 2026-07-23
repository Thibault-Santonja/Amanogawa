#!/usr/bin/env bash
# amanogawa_rotate_backups.sh -- prunes amanogawa_*.dump backups on an
# rclone remote, keeping 7 daily + 4 weekly + 6 monthly (issue #028).
#
# Split out of pg_backup.sh (which calls this script after a successful
# upload) so each script keeps a single responsibility: one dumps and
# uploads, this one only ever decides what to keep and what to delete.
# Targets GNU date (the VPS runs Debian); `date -d`/`%G-%V` are GNU
# extensions, not portable to BSD/macOS date.

set -euo pipefail

readonly SCRIPT_NAME="amanogawa_rotate_backups"
readonly REMOTE="${1:?usage: rotate_backups.sh <rclone-remote>}"
readonly DAILY_KEEP=7
readonly WEEKLY_KEEP=4
readonly MONTHLY_KEEP=6

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

date_part() {
  local filename=$1
  filename="${filename#amanogawa_}"
  filename="${filename%.dump}"
  printf '%s' "$filename"
}

mapfile -t files < <(rclone lsf "$REMOTE" | grep -E '^amanogawa_[0-9]{4}-[0-9]{2}-[0-9]{2}\.dump$' | sort -r)

if [[ ${#files[@]} -eq 0 ]]; then
  log "no backups found on $REMOTE, nothing to rotate"
  exit 0
fi

declare -A keep

# Daily: the DAILY_KEEP most recent dumps outright.
for ((i = 0; i < ${#files[@]} && i < DAILY_KEEP; i++)); do
  keep["${files[$i]}"]=1
done

# Weekly: the newest dump of each of the WEEKLY_KEEP most recent distinct
# ISO weeks. `files` is already sorted newest-first, so the first dump
# seen for a given week is that week's newest.
declare -A seen_weeks
weekly_count=0
for file in "${files[@]}"; do
  [[ $weekly_count -lt $WEEKLY_KEEP ]] || break
  week_key="$(date -u -d "$(date_part "$file")" +%G-%V)"
  if [[ -z "${seen_weeks[$week_key]:-}" ]]; then
    seen_weeks[$week_key]=1
    keep["$file"]=1
    weekly_count=$((weekly_count + 1))
  fi
done

# Monthly: same idea, grouped by calendar month.
declare -A seen_months
monthly_count=0
for file in "${files[@]}"; do
  [[ $monthly_count -lt $MONTHLY_KEEP ]] || break
  month_key="$(date -u -d "$(date_part "$file")" +%Y-%m)"
  if [[ -z "${seen_months[$month_key]:-}" ]]; then
    seen_months[$month_key]=1
    keep["$file"]=1
    monthly_count=$((monthly_count + 1))
  fi
done

log "retention: ${#keep[@]} dump(s) kept out of ${#files[@]} found on $REMOTE"

deleted=0
for file in "${files[@]}"; do
  if [[ -z "${keep[$file]:-}" ]]; then
    log "deleting $file"
    rclone deletefile "${REMOTE}/${file}"
    deleted=$((deleted + 1))
  fi
done

log "rotation complete: $deleted dump(s) deleted, ${#keep[@]} retained"
