---
title: Getting Started
---

# 01 - Getting Started

This repository provides an opinionated, production-only fork and template of `frappe_docker`. It eliminates development-specific overhead and focuses entirely on reproducible, immutable production deployments.

---

## Architectural Principles

### 1. Immutable Container Images
Unlike local development environments that rely on bind mounting source code into containers, production setups treat containers as immutable artifacts:
- Python packages, Node.js dependencies, Frappe Framework, and all custom apps are baked directly into the image layers during `docker build`.
- No live-reloading or container-internal file editing.

### 2. Accumulating Shared Assets
Frappe asset filenames are stamped with content hashes. In standard deployments, mounting an empty volume over `sites/assets` shadows baked image files.
In this setup:
- Assets are baked into `/home/frappe/frappe-bench/assets`.
- Containers mount a shared volume at `/home/frappe/frappe-bench/shared-assets`.
- `main-entrypoint.sh` computes an md5 checksum of the baked asset tree and copies new/updated assets into the shared volume if `.build-<hash>` is missing.
- `sites/assets` is symlinked to `shared-assets`.
- Old hashed bundles remain available on disk during and after rolling updates, preventing 404 errors for active client sessions.

### 3. Dynamic Nginx DNS Resolution
During container rollouts, backend container IPs change. To prevent Nginx from caching stale IPs:
- `nginx-entrypoint.sh` extracts the runtime nameserver from `/etc/resolv.conf`.
- `nginx-template.conf` sets `resolver ${NGINX_RESOLVER} valid=10s ipv6=off;` and assigns upstream endpoints to variables (`set $backend_upstream ${BACKEND}; proxy_pass http://$backend_upstream;`).
- Nginx re-resolves the upstream dynamically on incoming requests without requiring a frontend restart.

### 4. Per-Project Single `.env` Compose Orchestration
Instead of passing `-f compose.yaml -f overrides/...` on every CLI invocation, Docker Compose reads:
- `COMPOSE_PROJECT_NAME`
- `COMPOSE_FILE` (colon-delimited absolute file list)

All operational commands become as simple as `docker compose --env-file <file> <command>`.

---

## Prerequisites

- **Docker Engine:** `23.0+` (BuildKit enabled by default for secret mounts).
- **Docker Compose:** `v2+`.
- **Docker Rollout Plugin (Recommended):** [docker-rollout](https://github.com/Wowu/docker-rollout) for zero-downtime rolling updates.
