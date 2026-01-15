FROM alpine:3.19

# =========================
# Install dependencies
# =========================
RUN apk add --no-cache \
    bash \
    curl \
    tar \
    gzip \
    ca-certificates \
    python3 \
    py3-pip

# =========================
# Install AWS CLI v2
# =========================
RUN apk add --no-cache aws-cli

# =========================
# Install MongoDB Database Tools (mongodump)
# =========================
RUN apk add --no-cache mongodb-tools

# =========================
# Create app dir
# =========================
WORKDIR /app

# =========================
# Copy backup script
# =========================
COPY backup.sh /app/backup.sh
RUN chmod +x /app/backup.sh

# =========================
# Runtime env defaults (override via compose)
# =========================
ENV BACKUP_ROOT=/backups \
    INTERVAL_DAYS=14 \
    S3_PREFIX=mongodb

# =========================
ENTRYPOINT ["/app/backup.sh"]
