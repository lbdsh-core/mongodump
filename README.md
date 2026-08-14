# MongoDB Backup to S3 (Docker)

This repository provides a **Docker container based on Alpine Linux** to perform **MongoDB backups** using `mongodump`, compress them, and **upload to Amazon S3 (or S3-compatible storage)**.

Backup behavior is **fully configurable via environment variables**, making it ideal for:

* Docker / Docker Compose
* External cron
* ECS / Kubernetes / VM

---

## ✨ Features

* ✅ MongoDB backup with `mongodump`
* ✅ `tar.gz` compression
* ✅ Upload to S3 with `aws-cli`
* ✅ Configuration **only via ENV**
* ✅ Alpine Linux (lightweight image)
* ✅ Configurable local retention


---

## 🔧 Environment Variables

### 🔴 Required

| Variable                | Description                    |
| ----------------------- | ------------------------------ |
| `MONGO_URI`             | MongoDB connection URI         |
| `S3_BUCKET`             | S3 bucket name                 |
| `AWS_ACCESS_KEY_ID`     | AWS Access Key                 |
| `AWS_SECRET_ACCESS_KEY` | AWS Secret Key                 |
| `AWS_DEFAULT_REGION`    | AWS region (e.g. `eu-north-1`) |

### 🟡 Optional

| Variable        | Default     | Description                         |
| --------------- | ----------- | ----------------------------------- |
| `S3_PREFIX`     | `mongodb`   | Path prefix in the bucket           |
| `INTERVAL`      | `14`        | Local retention (days)              |
| `CRON_SCHEDULE` | `0 2 * * *` | Cron schedule for automatic backups |

---

## 🚦 Run modes

The image has two modes, selected by the command passed to the container:

| Command            | Behaviour                                                              |
| ------------------ | ---------------------------------------------------------------------- |
| `cron` *(default)* | Installs the crontab and stays running, backing up on `CRON_SCHEDULE`. |
| `backup`           | Runs a single backup and exits. Use it for one-off runs, restores tests and external schedulers. |

---

## 🐳 Docker

### ▶️ Build the image

The Dockerfile lives in `ci/`, so build from the repository root:

```bash
docker build -f ci/Dockerfile -t mongo-backup-s3 .
```

---

### ▶️ Scheduled backups (long-running container)

```bash
docker run -d --name mongo-backup \
    -e MONGO_URI="mongodb://user:password@mongo:27017/" \
    -e S3_BUCKET="my-backup-bucket" \
    -e S3_PREFIX="mongodb" \
    -e AWS_ACCESS_KEY_ID="AKIA..." \
    -e AWS_SECRET_ACCESS_KEY="SECRET..." \
    -e AWS_DEFAULT_REGION="eu-north-1" \
    -e INTERVAL=14 \
    -e CRON_SCHEDULE="0 2 * * *" \
    -v $(pwd)/backups:/mongodb \
    ghcr.io/lbd-core/mongodump:latest
```

### ▶️ One-off backup

```bash
docker run --rm \
    -e MONGO_URI="mongodb://user:password@mongo:27017/" \
    -e S3_BUCKET="my-backup-bucket" \
    -e AWS_ACCESS_KEY_ID="AKIA..." \
    -e AWS_SECRET_ACCESS_KEY="SECRET..." \
    -e AWS_DEFAULT_REGION="eu-north-1" \
    -v $(pwd)/backups:/mongodb \
    ghcr.io/lbd-core/mongodump:latest backup
```

Backups will be saved locally in `./backups` and uploaded to S3.

If a required variable is missing the container fails immediately at startup
instead of waiting until the first scheduled run.

---

## 🧩 Docker Compose

### ▶️ `docker-compose.yml`

```yaml
version: "3.9"

services:
  mongo-backup:
    image: ghcr.io/lbd-core/mongodump:latest
    environment:
      MONGO_URI: "mongodb://user:password@mongo:27017/"
      S3_BUCKET: "my-backup-bucket"
      S3_PREFIX: "mongodb"    
      AWS_ACCESS_KEY_ID: "AKIA..."
      AWS_SECRET_ACCESS_KEY: "SECRET..."
      AWS_DEFAULT_REGION: "eu-north-1"
      INTERVAL: 14
      CRON_SCHEDULE: "0 2 * * *"
    volumes:
        - ./backups:/mongodb
```

### ▶️ Run

Scheduled backups (the container stays up and runs on `CRON_SCHEDULE`):

```bash
docker compose up -d mongo-backup
```

A single backup on demand:

```bash
docker compose run --rm mongo-backup backup
```

---

## 📝 Logs

Both modes write a structured log to `/mongodb/backup.log` — `./backups/backup.log`
with the volume above — including the output of `mongodump` and `aws`:

```text
[2026-01-15 02:00:01] [INFO] [run=20260115T020001Z-42] [1/5] Dumping MongoDB into /mongodb/backup/2026-01-15_02-00 ...
[2026-01-15 02:00:09] [INFO] [run=20260115T020001Z-42] [1/5] Dump completed in 8s - size 412M, 3 database(s): admin appdb sessions
[2026-01-15 02:00:31] [INFO] [run=20260115T020001Z-42] [4/5] Upload completed in 14s -> s3://my-backup-bucket/mongodb/2026-01-15_02-00/2026-01-15_02-00.tar.gz
```

Credentials are masked. A failed run logs the step, the exit code and the
failing command, and the temporary dump is kept on disk for inspection.

```bash
docker compose exec mongo-backup tail -f /mongodb/backup.log
```

The cron daemon's own log (job start times, scheduling errors) is kept
separately in `/mongodb/cron.log`.

---

## 📁 S3 Structure

```text
s3://my-backup-bucket/
└── mongodb/
    └── 2026-01-15_02-00/
        └── 2026-01-15_02-00.tar.gz
```

---

## 🔁 Restore

The archive contains the dump directories at its root (`admin/`, `appdb/`, …),
so extract it into a directory of its own and point `mongorestore` at that:

```bash
aws s3 cp \
    s3://my-backup-bucket/mongodb/2026-01-15_02-00/2026-01-15_02-00.tar.gz \
    .

mkdir -p restore
tar -xzf 2026-01-15_02-00.tar.gz -C restore

mongorestore --gzip --uri="mongodb://user:password@mongo:27017/" restore
```

---

## ⏱ Scheduling

### Built-in cron (default)

Start the container and let it schedule itself with `CRON_SCHEDULE`:

```bash
docker compose up -d mongo-backup
```

The container snapshots its configuration at startup and passes it to the cron
job, so the scheduled run sees the same variables you set on the container.

### External cron

If you prefer to drive it from the host scheduler, use the `backup` command so
the container performs one backup and exits:

```cron
0 2 * * * docker compose run --rm mongo-backup backup
```

Do not combine the two: pick either the built-in schedule or the external one.