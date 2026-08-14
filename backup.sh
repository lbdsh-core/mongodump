#!/bin/bash
set -eEuo pipefail

# =========================
# LOGGING
# =========================
# Everything goes to the console (stdout/stderr) - no log file. Under cron the
# job's output is redirected to PID 1's stdout so it shows up in `docker logs`.
BACKUP_ROOT="${BACKUP_ROOT:-/mongodb/backup}"
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")-$$"

# Colours only on an interactive terminal, so they do not pollute `docker logs`.
if [ -t 1 ]; then
  C_INFO=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_OFF=$'\033[0m'
else
  C_INFO=""; C_WARN=""; C_ERR=""; C_OFF=""
fi

# Redact the credentials of any URI on a log line. The character class stops at
# the first '/', so it never leaves the authority section, and it is greedy: a
# password containing '@' or spaces is masked in full. Applied to every line
# because mongodump echoes the connection string back in its error messages.
scrub() {
  case "$1" in
    *://*@*) printf '%s' "$1" | sed -E 's#([a-zA-Z0-9+.-]+://)[^/]*@#\1***:***@#g' ;;
    *)       printf '%s' "$1" ;;
  esac
}

_log() {
  local level="$1" colour="$2"; shift 2
  local line="[$(date -u +"%Y-%m-%d %H:%M:%S")] [$level] [run=$RUN_ID] $(scrub "$*")"
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

# Pipe a command's own output into the log, one prefixed line at a time.
log_stream() { local tag="$1"; while IFS= read -r out_line; do log "$tag   > $out_line"; done; }

# Human readable size of a file or a directory.
size_of() { du -sh "$1" 2>/dev/null | cut -f1; }

# =========================
# FAILURE / COMPLETION REPORTING
# =========================
STEP="startup"
DEST_DIR=""

on_error() {
  local code="$1" line_no="$2" cmd="$3"
  log_error "Step '$STEP' FAILED at line $line_no (exit $code): $cmd"
  if [ -n "$DEST_DIR" ] && [ -d "$DEST_DIR" ]; then
    log_error "Temporary dump left on disk for inspection: $DEST_DIR"
  fi
}

on_exit() {
  local code=$?
  if [ "$code" -eq 0 ]; then
    log "Backup run finished successfully in ${SECONDS}s"
  else
    log_error "Backup run ABORTED after ${SECONDS}s during step '$STEP' (exit $code)"
  fi
  exit "$code"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
trap on_exit EXIT

# =========================
# REQUIRED ENV VARS
# =========================
STEP="env validation"

require_env() {
  local missing=0 var
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      log_error "Missing required environment variable: $var"
      missing=$((missing + 1))
    fi
  done
  if [ "$missing" -gt 0 ]; then
    log_error "$missing required variable(s) missing - the process did not receive them."
    log_error "If this run was started by cron, note that cron does NOT inherit the container environment."
    exit 1
  fi
}

log "===== MongoDB backup starting (pid $$, invoked as '$0') ====="
require_env MONGO_URI S3_BUCKET \
            AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

# Optional variables, with the defaults documented in the README.
if [ -z "${S3_PREFIX:-}" ]; then
  S3_PREFIX="mongodb"
  log "S3_PREFIX not set, using the default '$S3_PREFIX'"
fi
if [ -z "${INTERVAL:-}" ]; then
  INTERVAL="14"
  log "INTERVAL not set, using the default $INTERVAL day(s)"
fi

DATE=$(date +"%Y-%m-%d_%H-%M")
DEST_DIR="$BACKUP_ROOT/$DATE"
ARCHIVE="$DEST_DIR.tar.gz"
S3_TARGET="s3://$S3_BUCKET/$S3_PREFIX/$DATE/$(basename "$ARCHIVE")"

log "Configuration for this run:"
log "  mongo uri        : $MONGO_URI"
log "  aws region       : $AWS_DEFAULT_REGION"
log "  s3 destination   : $S3_TARGET"
log "  local dump dir   : $DEST_DIR"
log "  local archive    : $ARCHIVE"
log "  local retention  : $INTERVAL day(s) under $BACKUP_ROOT"

STEP="workspace preparation"
mkdir -p "$BACKUP_ROOT"
mkdir -p "$DEST_DIR"
log "Workspace ready (free space on $BACKUP_ROOT: $(df -h "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2 {print $4}'))"

# =========================
STEP="mongodump"
log "[1/5] Dumping MongoDB into $DEST_DIR ..."
step_start=$SECONDS

mongodump \
  --uri="$MONGO_URI" \
  --gzip \
  --out="$DEST_DIR" 2>&1 | log_stream "[1/5]"

dumped_dbs=$(ls -1 "$DEST_DIR" 2>/dev/null | tr '\n' ' ')
db_count=$(ls -1 "$DEST_DIR" 2>/dev/null | wc -l | tr -d ' ')
log "[1/5] Dump completed in $((SECONDS - step_start))s - size $(size_of "$DEST_DIR"), $db_count database(s): ${dumped_dbs:-<none>}"
if [ "$db_count" -eq 0 ]; then
  log_warn "[1/5] mongodump produced no database directory - the archive will be empty. Check MONGO_URI and the user's permissions."
fi

# =========================
STEP="compression"
log "[2/5] Compressing the dump into $ARCHIVE ..."
step_start=$SECONDS

tar -czf "$ARCHIVE" -C "$DEST_DIR" . 2>&1 | log_stream "[2/5]"

log "[2/5] Archive created in $((SECONDS - step_start))s - size $(size_of "$ARCHIVE")"

# =========================
STEP="cleanup of temporary dump"
log "[3/5] Removing the temporary dump directory $DEST_DIR ..."

rm -rf "$DEST_DIR"
DEST_DIR=""

log "[3/5] Temporary dump directory removed"

# =========================
STEP="upload to S3"
log "[4/5] Uploading $(basename "$ARCHIVE") to $S3_TARGET ..."
step_start=$SECONDS

aws s3 cp \
  "$ARCHIVE" \
  "$S3_TARGET" 2>&1 | log_stream "[4/5]"

log "[4/5] Upload completed in $((SECONDS - step_start))s -> $S3_TARGET"

# =========================
STEP="local retention"
if ! printf '%s' "$INTERVAL" | grep -Eq '^[0-9]+$'; then
  log_error "INTERVAL must be a whole number of days, got '$INTERVAL' - skipping the retention step."
  exit 1
fi

log "[5/5] Removing local backups older than $INTERVAL day(s) from $BACKUP_ROOT ..."
removed_count=0
freed=""
while IFS= read -r old_file; do
  freed=$(size_of "$old_file")
  log "[5/5]   removing $old_file ($freed)"
  rm -f "$old_file"
  removed_count=$((removed_count + 1))
done < <(find "$BACKUP_ROOT" -type f -mtime +"$INTERVAL")

log "[5/5] Retention done - $removed_count old file(s) removed, $(ls -1 "$BACKUP_ROOT" 2>/dev/null | wc -l | tr -d ' ') file(s) still held locally"

log "Backup completed and uploaded to S3: $S3_TARGET"
