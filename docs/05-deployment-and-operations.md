---
title: Deployment and Operations
---

# 05 - Deployment, Rollout & Site Operations

---

## 1. Bench & Site Operations

Run bench commands against the running `backend` container:

### Creating a New Site
```bash
docker compose --env-file ~/gitops/.env.erpnext-prod exec backend \
  bench new-site erp.example.com \
  --mariadb-user-host-login-scope='172.%.%.%' \
  --db-root-password strongpassword \
  --admin-password admin \
  --install-app erpnext \
  --install-app hrms
```

### Running Schema Migrations
```bash
docker compose --env-file ~/gitops/.env.erpnext-prod exec backend \
  bench --site all migrate
```

### Backing Up Sites
```bash
docker compose --env-file ~/gitops/.env.erpnext-prod exec backend \
  bench --site all backup --with-files
```

---

## 2. Zero-Downtime Rollout (`rollout.sh`)

When deploying a new image tag (`CUSTOM_TAG=v16.1.0`), invoke `rollout.sh`:

```bash
./rollout.sh ~/gitops/.env.erpnext-prod
```

### Lifecycle:
1. **Pre-Swap Migration:** Runs `bench --site all migrate` inside a temporary one-off container while the live containers continue serving traffic.
2. **Graceful Traffic Drain & Swap:** Rolls `frontend`, `backend`, and `websocket` sequentially with a drain hook (`touch /tmp/drain && sleep 10`) ensuring active HTTP requests finish before container teardown.
3. **Background Services Update:** Recreates non-traffic services (`configurator`, `queue-short`, `queue-long`, `scheduler`).
4. **Cache Invalidation:** Flushes the cached `assets_json` key in Redis (`DEL assets_json`) and runs `bench clear-cache`.

---

## 3. Post-Rollout Verification (`verify.sh`)

Audit container health and routing immediately following a rollout:

```bash
./verify.sh ~/gitops/.env.erpnext-prod
```

Expected output:
```text
backend container IP: 172.18.0.5
nginx last upstream : 172.18.0.5:8000
(if those two differ, nginx is on a stale IP — resolver cache)

PASS  frontend -> backend proxy (200)
PASS  asset /assets/frappe/dist/css/frappe-web.bundle.XXXXX.css (200)
```

---

## 4. Staging Site Restore & Sanitization

To refresh a staging site from production without exposing live third-party integrations:

1. Add `compose.restore.yaml` and `compose.sanitize.yaml` to the staging `COMPOSE_FILE`.
2. Configure `RESTORE_SITE`, `RESTORE_SOURCE_URL`, and `RESTORE_SOURCE_TOKEN` in the staging env file.
3. Execute restore and sanitization:
   ```bash
   docker compose --env-file ~/gitops/.env.staging --profile restore run --rm restore
   docker compose --env-file ~/gitops/.env.staging --profile sanitize run --rm sanitize
   ```

### What Sanitization Disables:
- Outgoing and incoming email accounts (`mute_emails`, `enable_outgoing=0`, `enable_incoming=0`).
- Unsent email queue items.
- Live Webhooks and automated document-event Notifications.
- Recurring auto-repeat tasks.
- SMS/Push Single DocTypes defined in `SANITIZE_SINGLES`.
