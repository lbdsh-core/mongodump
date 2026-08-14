#!/bin/bash
set -euo pipefail

# =========================
# Container entrypoint. All logging goes to the console (`docker logs`).
#
#   cron   (default) install the crontab and supervise crond
#   backup            run a single backup and exit - `docker compose run --rm`
#   <other>           executed as-is, e.g. `docker run ... image bash`
# =========================

log() {
  printf '[%s] [INFO] [entrypoint] %s\n' "$(date -u +"%Y-%m-%d %H:%M:%S")" "$*"
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

    # crond must NOT be PID 1: PID 1 is the session leader of the container and
    # dcron's setpgid(0,0) then fails with EPERM ("setpgid: Operation not
    # permitted"). Keeping this shell as PID 1 and running the daemon as a child
    # avoids that, and lets us forward signals for a clean shutdown.
    log "Starting crond, its own messages go to the console as well"
    crond -f -L /dev/stdout &
    CROND_PID=$!

    trap 'log "Shutdown signal received, stopping crond"; kill -TERM "$CROND_PID" 2>/dev/null || true' TERM INT

    status=0
    wait "$CROND_PID" || status=$?
    log "crond exited with status $status"
    exit "$status"
    ;;

  *)
    log "Executing custom command: $*"
    exec "$@"
    ;;
esac
