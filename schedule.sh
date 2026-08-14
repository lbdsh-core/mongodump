#!/bin/bash
set -euo pipefail

# =========================
# LOGGING
# =========================
# Everything goes to the console, no log file. Cron jobs do not inherit the
# container's stdout, so scheduled runs are redirected to PID 1's stdout - that
# is the file descriptor `docker logs` reads.
CONSOLE="${CONSOLE:-/proc/1/fd/1}"

if [ -t 1 ]; then
  C_INFO=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

_log() {
  local level="$1" colour="$2"; shift 2
  local line="[$(date -u +"%Y-%m-%d %H:%M:%S")] [$level] [scheduler] $*"
  if [ "$level" = "ERROR" ]; then
    printf '%s%s%s\n' "$colour" "$line" "$C_OFF" >&2
  else
    printf '%s%s%s\n' "$colour" "$line" "$C_OFF"
  fi
  return 0
}

log()       { _log "INFO"  "$C_INFO" "$@"; }
log_warn()  { _log "WARN"  "$C_WARN" "$@"; }
log_error() { _log "ERROR" "$C_ERR"  "$@"; }

trap 'log_error "Scheduler failed - no cron job was installed"' ERR

# Set default cron schedule if not provided
CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"

# Path to mongodump script (absolute: cron resolves relative paths against $HOME)
MONGODUMP_SCRIPT="$(cd "$(dirname "$0")" && pwd)/backup.sh"

# Where the container configuration is snapshotted for the cron job (see below)
BACKUP_ENV_FILE="${BACKUP_ENV_FILE:-/app/backup.env}"

log "===== Installing the backup cron job ====="
log "  backup script : $MONGODUMP_SCRIPT"
log "  schedule      : $CRON_SCHEDULE"
log "  env snapshot  : $BACKUP_ENV_FILE"
log "  console       : $CONSOLE"

if [ ! -w "$CONSOLE" ]; then
  log_warn "$CONSOLE is not writable - scheduled runs will not show up in 'docker logs'"
fi

if [ ! -f "$MONGODUMP_SCRIPT" ]; then
  log_error "Backup script not found at $MONGODUMP_SCRIPT - nothing to schedule"
  exit 1
fi
if [ ! -x "$MONGODUMP_SCRIPT" ]; then
  log_warn "Backup script is not executable, cron will run it through 'bash'"
fi

# =========================
# CONFIGURATION CHECK
# =========================
# Fail here, at container start, instead of silently at 02:00.
missing=0
for var in MONGO_URI S3_BUCKET AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION; do
  if [ -z "${!var:-}" ]; then
    log_error "Missing required environment variable: $var"
    missing=$((missing + 1))
  fi
done
if [ "$missing" -gt 0 ]; then
  log_error "$missing required variable(s) missing - refusing to schedule a backup that cannot work"
  exit 1
fi

# =========================
# ENVIRONMENT SNAPSHOT
# =========================
# cron starts jobs with an almost empty environment: without this snapshot the
# scheduled run would not see MONGO_URI, the AWS credentials or S3_BUCKET, and
# backup.sh would abort on every single run.
SECRET_VARS=" AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN MONGO_URI "
EXPORTED_VARS=(
  MONGO_URI
  S3_BUCKET S3_PREFIX
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_DEFAULT_REGION AWS_ENDPOINT_URL
  INTERVAL
  BACKUP_ROOT
)

umask 077
: > "$BACKUP_ENV_FILE"
chmod 600 "$BACKUP_ENV_FILE"

captured=()
for var in "${EXPORTED_VARS[@]}"; do
  [ -z "${!var:-}" ] && continue
  printf 'export %s=%q\n' "$var" "${!var}" >> "$BACKUP_ENV_FILE"
  case "$SECRET_VARS" in
    *" $var "*) captured+=("$var=<hidden>") ;;
    *)          captured+=("$var=${!var}") ;;
  esac
done

log "Configuration snapshotted for cron (mode 600, ${#captured[@]} variable(s)):"
for entry in "${captured[@]}"; do
  log "  | $entry"
done

# =========================
# BUILD THE NEW CRONTAB
# =========================
CRON_FILE="$(mktemp)"
trap 'rm -f "$CRON_FILE"' EXIT

# Write out current crontab
if crontab -l > "$CRON_FILE" 2>/dev/null; then
  log "Existing crontab loaded ($(wc -l < "$CRON_FILE" | tr -d ' ') line(s))"
else
  : > "$CRON_FILE"
  log "No existing crontab found, starting from an empty one"
fi

# Drop any previous entry for this backup script
stale=$(grep -c 'backup\.sh' "$CRON_FILE" || true)
if [ "$stale" -gt 0 ]; then
  log "Removing $stale stale backup entry/entries from the crontab"
fi
sed -i '/backup\.sh/d' "$CRON_FILE"

# Add new cron job:
#  - bash -c, so the %q quoting written above is interpreted by bash and not by sh
#  - the env snapshot is sourced first, otherwise the job sees no configuration
#  - the redirect sends the run to PID 1's stdout, i.e. to `docker logs`
CRON_CMD="bash -c '. $BACKUP_ENV_FILE && exec bash \"$MONGODUMP_SCRIPT\"'"
CRON_LINE="$CRON_SCHEDULE $CRON_CMD >> $CONSOLE 2>&1"
# '%' is a newline for cron and must be escaped inside the command
CRON_LINE="${CRON_LINE//%/\\%}"
printf '%s\n' "$CRON_LINE" >> "$CRON_FILE"

# Install new cron file
crontab "$CRON_FILE"

log "Crontab installed, current content:"
crontab -l 2>/dev/null | while IFS= read -r entry; do
  [ -n "$entry" ] && log "  | $entry"
done

log "Scheduled backup with cron: $CRON_SCHEDULE"
log "Scheduled runs print to the container console - follow them with: docker logs -f <container>"
