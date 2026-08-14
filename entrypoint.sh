#!/bin/bash
set -euo pipefail

# =========================
# Container entrypoint.
#
#   cron   (default) install the crontab and keep crond in the foreground
#   backup            run a single backup and exit - `docker compose run --rm`
#   <other>           executed as-is, e.g. `docker run ... image bash`
# =========================

LOG_FILE="${LOG_FILE:-/mongodb/backup.log}"
CRON_LOG="${CRON_LOG:-/mongodb/cron.log}"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$CRON_LOG")"

log() {
  local line="[$(date -u +"%Y-%m-%d %H:%M:%S")] [INFO] [entrypoint] $*"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG_FILE"
}

MODE="${1:-cron}"

case "$MODE" in
  backup|once|now)
    log "Mode '$MODE': running a single backup, the container will exit when it finishes"
    exec /app/backup.sh
    ;;

  cron|schedule)
    log "Mode '$MODE': scheduling automatic backups"
    /app/schedule.sh
    log "Handing over to crond (foreground). Daemon log: $CRON_LOG, backup log: $LOG_FILE"
    exec crond -f -L "$CRON_LOG"
    ;;

  *)
    log "Executing custom command: $*"
    exec "$@"
    ;;
esac
