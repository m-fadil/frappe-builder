---
title: Multi-Project Env and Compose Setup
---

# 04 - Multi-Project Env & Compose Setup

Instead of manually passing `-p <project>` and `-f <file>` flags on every Compose invocation, Compose can read both the project identity and the ordered file merge list directly from an environment file.

---

## 1. Creating a Dedicated Project Env File

Keep project env files separated (e.g. in a private gitops repository or deployment directory):

```bash
mkdir -p ~/gitops
cp example.env ~/gitops/.env.erpnext-prod
```

Configure `COMPOSE_PROJECT_NAME` and `COMPOSE_FILE` at the head of `~/gitops/.env.erpnext-prod`:

```env
COMPOSE_PROJECT_NAME=erpnext-prod
COMPOSE_FILE=/opt/custom_frappe_docker/compose.yaml:/opt/custom_frappe_docker/overrides/compose.mariadb.yaml:/opt/custom_frappe_docker/overrides/compose.redis.yaml:/opt/custom_frappe_docker/overrides/compose.noproxy.yaml
```

> **Note on Paths:** Always use **absolute paths** in `COMPOSE_FILE`. This allows Compose commands, systemd units, and cron jobs to execute from any working directory.

---

## 2. Key Environment Variables

```env
# Target Image
CUSTOM_IMAGE=ghcr.io/your-org/custom-frappe
CUSTOM_TAG=16.0.0
PULL_POLICY=always

# Database Configuration
DB_PASSWORD=strongpassword
DB_HOST=mariadb
DB_PORT=3306

# Frontend & Reverse Proxy
PORT=8080
FRAPPE_SITE_NAME_HEADER=erp.example.com
PROXY_READ_TIMEOUT=120
CLIENT_MAX_BODY_SIZE=50m

# Gunicorn Backend Performance
GUNICORN_WORKERS=2
GUNICORN_THREADS=4
GUNICORN_TIMEOUT=120
```

---

## 3. Running Compose Commands

Execute all actions by passing `--env-file`:

```bash
# Validate resolved configuration
docker compose --env-file ~/gitops/.env.erpnext-prod config

# Launch services in background
docker compose --env-file ~/gitops/.env.erpnext-prod up -d

# Tail logs
docker compose --env-file ~/gitops/.env.erpnext-prod logs -f backend

# Tear down services
docker compose --env-file ~/gitops/.env.erpnext-prod down
```
