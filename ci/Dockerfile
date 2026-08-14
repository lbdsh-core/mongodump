
FROM alpine:3.19

RUN apk add --no-cache bash curl tar gzip ca-certificates python3 py3-pip dcron
RUN apk add --no-cache aws-cli
RUN apk add --no-cache mongodb-tools
WORKDIR /app
VOLUME /mongodb
COPY backup.sh /app/backup.sh
COPY schedule.sh /app/schedule.sh
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/backup.sh /app/schedule.sh /app/entrypoint.sh

# Defaults for the optional variables documented in the README
ENV S3_PREFIX="mongodb" \
    INTERVAL="14" \
    CRON_SCHEDULE="0 2 * * *"

# Default mode installs the crontab and keeps crond in the foreground.
# Pass "backup" instead to run a single backup and exit.
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["cron"]
