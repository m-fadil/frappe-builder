---
title: Image Build and CI/CD Pipeline
---

# 03 - Image Build & CI/CD Pipeline

This document explains the image build lifecycle, the strict separation between Build-Time and Runtime secrets, and the automated GitHub Actions CI/CD workflows.

---

## 1. Build-Time vs. Runtime Secrets Architecture

A core design rule of this setup is the **strict separation between Build-Time artifacts and Runtime configurations**:

```text
[ BUILD-TIME (CI / GitHub Actions) ]
  • apps.json + Git PATs (from GitHub Secrets)
  • Source code & asset compilation
  • Output: Immutable Docker Image (e.g., ghcr.io/org/custom-frappe:v1.2.0)
         │
         │ (Pushed to Registry - NO runtime .env or DB credentials inside)
         ▼
[ RUNTIME (Production Server / Target Host) ]
  • Target Server .env (DB_PASSWORD, SITES_RULE, PORT, REDIS_CACHE, etc.)
  • Reads CUSTOM_TAG=v1.2.0
  • Execution: docker compose --env-file .env up -d / ./rollout.sh .env
```

| Scope | Artifact / Secret | Where Stored | Handled By |
|---|---|---|---|
| **Build-Time** | Git PATs / `.netrc` (`NETRC`), `apps.json` | GitHub Repository Secrets | BuildKit Secret Mounts (`--secret id=apps_json`, `--secret id=netrc`) |
| **Runtime** | Database passwords, SMTP keys, API tokens, `.env` files | Target Server / GitOps Repo / CD Secrets | Docker Compose runtime environment (`--env-file`) |

> **Crucial Rule:** The deployment `.env` file is **never baked into the container image**. The image remains a generic, reusable artifact across development, staging, and production environments.

---

Build the production image locally using Docker Buildx:

```bash
# Optional: resolve token placeholders embedded directly in apps.json URLs
export CRM_PAT="ghp_xxx"
envsubst < apps.json > /tmp/apps.json

# Optional: private apps authenticated via .netrc instead (recommended, see
# docs/02-custom-apps.md) — copy example.netrc to build.netrc and fill in
# real tokens; build.netrc is gitignored.

docker build \
  --no-cache \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH=version-16 \
  --secret id=apps_json,src=/tmp/apps.json \
  --secret id=netrc,src=build.netrc \
  --tag my-org/custom-frappe:16.0.0 \
  --file Containerfile .

rm /tmp/apps.json
```

Drop `--secret id=netrc` if none of the apps are private.

### Build Arguments:

| Argument | Default | Purpose |
|---|---|---|
| `FRAPPE_PATH` | `https://github.com/frappe/frappe` | Git URL for Frappe framework |
| `FRAPPE_BRANCH` | `version-16` | Git branch or tag for Frappe framework |
| `PYTHON_VERSION` | `3.14` | Base Python runtime version |
| `NODE_VERSION` | `24` | Node.js runtime for asset compilation |
| `INSTALL_CHROMIUM` | `true` | Installs `chromium-headless-shell` for PDF/print generation |
| `CACHE_BUST` | `""` | Arbitrary string to invalidate build cache |

#### Forcing apps to be re-pulled (`CACHE_BUST`)

`bench init` clones every app in one cached layer, so a new commit upstream on an
unchanged branch will *not* be picked up — BuildKit reuses the layer. `CACHE_BUST`
is referenced inside that `RUN` (`Containerfile:134`), so changing its value
invalidates the layer and forces a fresh clone of Frappe and all apps.

Any new value works; a date or the upstream commit SHA is the readable choice.

**Locally:**

```bash
docker build -f Containerfile --build-arg CACHE_BUST=$(date +%F) -t custom-frappe:local .
```

**Release workflow, one-off:** Actions → *Release* → **Run workflow** → fill the
`cache_bust` input. Nothing to commit.

**Automatic on `release.yml`:** a *Resolve upstream app revisions* step runs
`git ls-remote` against Frappe and every entry in `apps.json`, and folds the
resulting commit SHAs into `CACHE_BUST`. A new commit on an unchanged branch
therefore rebuilds on its own — a tag push alone would otherwise reuse the
cached `bench init` layer and republish identical app code under a new tag.
The step fails the build if a branch cannot be resolved; URLs may embed PATs,
so only the 16-char digest is ever printed. Private apps authenticated via
`.netrc` instead of an embedded PAT resolve too — the workflow installs the
`NETRC` secret at the runner's `$HOME/.netrc` before this step runs.

`ci.yml` deliberately skips this: PR builds are frequent and it is a smoke
test, not a supply-chain gate. Use the variable below to bust CI on demand.

**Every build until changed again:** set a repository variable (Settings → Secrets
and variables → Actions → *Variables* tab) named `CACHE_BUST`. Both `ci.yml` and
`release.yml` read `vars.CACHE_BUST`; bump it when you want apps re-pulled, leave
it empty (or unset) to keep builds cache-warm. The `workflow_dispatch` input
overrides the variable for that single run.

Pin instead of bust where you can: an exact `branch` or tag per app in
`apps.json` is reproducible, `CACHE_BUST` is a hammer that rebuilds everything
from `bench init` onward (~30-45 min).

---

## 3. GitHub Actions Workflows

### A. Continuous Integration (`ci.yml`)
Triggers automatically on Pull Requests and pushes to `main`, `master`, `develop`, or `custom/*` branches:
- Injects repository secrets into `apps.json`.
- Builds a temporary image with BuildKit secret mounts.
- Executes container smoke tests (verifies Frappe apps, `assets.json` generation, and `bench --version`).

### B. Automated Release Pipeline (`release.yml`)
Triggers on Git Tag pushes matching `v*.*.*` (e.g. `v16.0.0`, `v1.2.3`):
1. **Verify Job:** Validates build integrity with smoke tests.
2. **Publish Job (Multi-Arch):**
   - Sets up QEMU and Buildx for `linux/amd64` and `linux/arm64`.
   - Authenticates to GitHub Container Registry (`ghcr.io`).
   - Uses `docker/metadata-action` to derive SemVer tags:
     - Tag `v16.3.0` emits `ghcr.io/<repo>:16.3.0`, `:16.3`, `:16`, and `:latest`.
   - Injects secrets into `apps.json` and compiles multi-arch images.
   - Pushes images to GHCR.
   - Attests image provenance with cryptographically verifiable **SLSA Provenance Attestations** (sigstore).

---

## 4. Continuous Deployment (CD) to Server

To automatically deploy the released image tag to a production server:

1. On the production server, update `CUSTOM_TAG` in your `.env` file (or maintain it via GitOps):
   ```env
   CUSTOM_IMAGE=ghcr.io/your-org/custom-frappe
   CUSTOM_TAG=v16.3.0
   ```

2. Execute the zero-downtime rollout script:
   ```bash
   ./rollout.sh .env.prod
   ./verify.sh .env.prod
   ```

If orchestrating deployment from GitHub Actions CD:
- Store the target server's SSH credentials (`SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`) in GitHub Secrets.
- Add a deployment job in GitHub Actions that connects to the host and triggers `./rollout.sh <env-file>`.
