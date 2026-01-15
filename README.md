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

| Variable        | Default   | Description               |
| --------------- | --------- | ------------------------- |
| `S3_PREFIX`     | `mongodb` | Path prefix in the bucket |
| `INTERVAL_DAYS` | `14`      | Local retention (days)    |

---

## 🐳 Docker

### ▶️ Build the image

```bash
docker build -t mongo-backup-s3 .
```

---

### ▶️ Run with `docker run`

```bash
docker run --rm \
    -e MONGO_URI="mongodb://user:password@mongo:27017/" \
    -e S3_BUCKET="my-backup-bucket" \
    -e S3_PREFIX="mongodb" \
    -e AWS_ACCESS_KEY_ID="AKIA..." \
    -e AWS_SECRET_ACCESS_KEY="SECRET..." \
    -e AWS_DEFAULT_REGION="eu-north-1" \
    -e INTERVAL=14 \
    -v $(pwd)/backups:/mongodb \
    ghcr.io/lbdsh-core/mongodump:latest
```

Backups will be saved locally in `./backups` and uploaded to S3.

---

## 🧩 Docker Compose

### ▶️ `docker-compose.yml`

```yaml
version: "3.9"

services:
  mongo-backup:
    image: ghcr.io/lbdsh-core/mongodump:latest
    environment:
      MONGO_URI: "mongodb://user:password@mongo:27017/"
      S3_BUCKET: "my-backup-bucket"
      S3_PREFIX: "mongodb"    
      AWS_ACCESS_KEY_ID: "AKIA..."
      AWS_SECRET_ACCESS_KEY: "SECRET..."
      AWS_DEFAULT_REGION: "eu-north-1"
      INTERVAL: 14
    volumes:
        - ./backups:/mongodb
```

### ▶️ Run

```bash
docker compose run --rm mongo-backup
```

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

```bash
aws s3 cp \
    s3://my-backup-bucket/mongodb/2026-01-15_02-00/2026-01-15_02-00.tar.gz \
    .

tar -xzf 2026-01-15_02-00.tar.gz

mongorestore --gzip 2026-01-15_02-00
```

---

## ⏱ Scheduling (recommended)

Use an **external cron**:

```cron
0 2 * * * docker compose run --rm mongo-backup
```