# custom_frappe_docker

Production-ready Frappe / ERPNext Docker build and deployment harness. Bundles custom apps via `apps.json` into self-contained immutable container images with zero-downtime rolling updates, automated assets accumulation, and per-project `.env`-driven Compose orchestration.

No development or debug images. Built strictly for reliable, reproducible production deployments.

---

## Architecture & Key Decisions

- **Single Self-Contained Image:** Frappe framework, official apps (e.g., ERPNext, HRMS), and custom apps are installed and baked during `docker build`. No source-code volume mounts at runtime.
- **BuildKit Secret Mounts:** `apps.json` and a `.netrc` file (for private Git hosts) are mounted strictly into build-step memory (`--mount=type=secret,id=apps_json`, `--mount=type=secret,id=netrc`). Credentials never leak into Docker layer history or `docker inspect`.
- **Accumulating Shared Assets:** Static assets are baked into image layers and merged by `main-entrypoint.sh` into a shared `shared-assets` volume upon startup. Content hashes avoid collisions and guarantee zero 404s for cached client sessions during rolling deployments.
- **Dynamic DNS Resolver in Nginx:** Frontend container detects internal DNS (`/etc/resolv.conf`) with a 10s TTL (`valid=10s`), eliminating stale IP caching when backend containers are swapped during rollouts.
- **Single `.env` Driven Compose:** Drives the entire compose stack without chaining repetitive `-f overrides/...` CLI flags. Define `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` directly inside your project env file.
- **Multi-Arch Tag Releases:** Automated GitHub Actions workflow (`v*.*.*` tags) produces multi-arch (`linux/amd64`, `linux/arm64`) images, SemVer tagging, GHCR publishing, and SLSA build provenance attestations.

---

## Repository Layout

```text
custom_frappe_docker/
├── Containerfile                  # Multi-stage production container build
├── apps.json                      # Custom Frappe apps definition
├── compose.yaml                   # Base production Compose definition
├── example.env                    # Full environment configuration template
├── example.netrc                  # Private Git host credentials template (see 02-custom-apps.md)
├── rollout.sh                     # Zero-downtime rolling update orchestration script
├── verify.sh                      # Post-rollout proxy and asset verification script
├── overrides/                     # Modular Compose overrides
│   ├── compose.mariadb.yaml       # Bundled MariaDB
│   ├── compose.mariadb-shared.yaml# Shared MariaDB instance
│   ├── compose.mariadb-secrets.yaml # MariaDB using Docker secrets
│   ├── compose.postgres.yaml      # PostgreSQL database backend
│   ├── compose.redis.yaml         # Redis Cache & Queue
│   ├── compose.noproxy.yaml       # Direct host port binding (:8080)
│   ├── compose.https.yaml         # Traefik HTTPS with Let's Encrypt
│   ├── compose.proxy.yaml         # Traefik HTTP router
│   ├── compose.nginxproxy.yaml    # nginx-proxy integration
│   ├── compose.nginxproxy-ssl.yaml# nginx-proxy + ACME companion
│   ├── compose.migrator.yaml      # Auto-migrator service
│   ├── compose.backup-cron.yaml   # Ofelia scheduled site backup service
│   ├── compose.restore.yaml       # Remote site backup restore service
│   ├── compose.sanitize.yaml      # Database sanitizer for staging clones
│   ├── compose.proxy-tunnel.yaml  # Cloudflare Quick Tunnel
│   └── compose.proxy-tunnel-token.yaml # Named Cloudflare Tunnel with token
├── resources/core/
│   ├── main-entrypoint.sh         # Symlink & asset merge entrypoint
│   ├── start.sh                   # Gunicorn WSGI startup script
│   └── nginx/                     # Frontend reverse proxy configuration
├── docs/                          # In-depth technical documentation
│   ├── 01-getting-started.md
│   ├── 02-custom-apps.md
│   ├── 03-build-and-ci.md
│   ├── 04-env-and-compose.md
│   └── 05-deployment-and-operations.md
└── .github/workflows/
    ├── ci.yml                     # PR and branch push smoke-test workflow
    └── release.yml                # Multi-arch tag-based release workflow
```

---

## Quickstart

### 1. Configure Apps in `apps.json`

Create or edit `apps.json` in the project root. URLs stay plain, no embedded tokens:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  },
  {
    "url": "https://github.com/frappe/hrms",
    "branch": "version-16"
  },
  {
    "url": "https://github.com/your-org/private-app.git",
    "branch": "main"
  }
]
```

> **Private Apps & Secrets:** Authenticate private entries with a `.netrc` file instead of embedding tokens in the URL. Copy [`example.netrc`](example.netrc) to `build.netrc` (gitignored) and fill in real tokens; the CI/CD workflows read the same credentials from a repository secret named `NETRC`. See [02. Custom Apps & Secrets Management](docs/02-custom-apps.md).

---

### 2. Build the Production Image

Run BuildKit with the secret mounts:

```bash
docker build \
  --no-cache \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH=version-16 \
  --secret id=apps_json,src=apps.json \
  --secret id=netrc,src=build.netrc \
  --tag ghcr.io/your-org/custom-frappe:16.0.0 \
  --file Containerfile .
```

Drop `--secret id=netrc` if none of the apps are private.

---

### 3. Deploy via Self-Contained `.env`

1. **Create an environment file for the target project:**
   ```bash
   cp example.env .env.prod
   ```

2. **Set `COMPOSE_FILE` and `COMPOSE_PROJECT_NAME` at the head of `.env.prod`:**
   ```env
   COMPOSE_PROJECT_NAME=erpnext-prod
   COMPOSE_FILE=/path/to/custom_frappe_docker/compose.yaml:/path/to/custom_frappe_docker/overrides/compose.mariadb.yaml:/path/to/custom_frappe_docker/overrides/compose.redis.yaml:/path/to/custom_frappe_docker/overrides/compose.noproxy.yaml

   CUSTOM_IMAGE=ghcr.io/your-org/custom-frappe
   CUSTOM_TAG=16.0.0
   PULL_POLICY=never
   ```

3. **Start the stack:**
   ```bash
   docker compose --env-file .env.prod up -d
   ```

4. **Initialize a site:**
   ```bash
   docker compose --env-file .env.prod exec backend \
     bench new-site erp.example.com \
     --db-root-password 123 \
     --admin-password admin \
     --install-app erpnext \
     --install-app hrms
   ```

5. **Perform Zero-Downtime Updates & Verification:**
   ```bash
   # Run rolling update
   ./rollout.sh .env.prod

   # Verify proxy upstreams and static assets
   ./verify.sh .env.prod
   ```

---

## Documentation Index

- [01. Architecture & Getting Started](docs/01-getting-started.md)
- [02. Custom Apps & Secrets Management](docs/02-custom-apps.md)
- [03. Image Build & CI/CD Release Pipeline](docs/03-build-and-ci.md)
- [04. Per-Project Env & Compose Configuration](docs/04-env-and-compose.md)
- [05. Deployment, Rollout & Site Operations](docs/05-deployment-and-operations.md)
