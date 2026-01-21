#!/bin/bash
set -e

# =========================
# REQUIRED ENV VARS
# =========================
: "${MONGO_URI:?Missing MONGO_URI}"
: "${S3_BUCKET:?Missing S3_BUCKET}"
: "${S3_PREFIX:?Missing S3_PREFIX}"
: "${AWS_ACCESS_KEY_ID:?Missing AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Missing AWS_SECRET_ACCESS_KEY}"
: "${AWS_DEFAULT_REGION:?Missing AWS_DEFAULT_REGION}"
: "${INTERVAL:?Missing INTERVAL}"

DATE=$(date +"%Y-%m-%d_%H-%M")
BACKUP_ROOT="/mongodb/backup"
LOG_FILE="/mongodb/backup.log"
DEST_DIR="$BACKUP_ROOT/$DATE"
ARCHIVE="$DEST_DIR.tar.gz"

mkdir -p "$BACKUP_ROOT"
mkdir -p "$DEST_DIR"

log() {
  echo -e "\033[32m[$(date -u +"%Y-%m-%d %H:%M:%S")] $1\033[0m"
  echo "[$(date -u +"%Y-%m-%d %H:%M:%S")] $1" >> "$LOG_FILE"
}

# =========================
log "Starting backup MongoDB"

mongodump \
  --uri="$MONGO_URI" \
  --gzip \
  --out="$DEST_DIR"

# =========================
log "Compressing backup"

tar -czf "$ARCHIVE" -C "$DEST_DIR" .

# =========================
log "Removing temporary backup directory"

rm -rf "$DEST_DIR"

# =========================
log "Uploading to S3..."
aws s3 cp \
  "$ARCHIVE" \
  "s3://$S3_BUCKET/$S3_PREFIX/$DATE/$(basename "$ARCHIVE")" \
  --only-show-errors 

# =========================
log "Removing local backups older than $INTERVAL days"
find "$BACKUP_ROOT" -type f -mtime +"$INTERVAL" -exec rm -f {} \;
log "Backup completed and uploaded to S3 "
