---
title: Image Build and CI/CD Pipeline
---

# 03 - Image Build & CI/CD Pipeline

---

## 1. Local Image Build

Build the production image locally using Docker Buildx:

```bash
docker build \
  --no-cache \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH=version-16 \
  --secret id=apps_json,src=apps.json \
  --tag my-org/custom-frappe:16.0.0 \
  --file Containerfile .
```

### Build Arguments:

| Argument | Default | Purpose |
|---|---|---|
| `FRAPPE_PATH` | `https://github.com/frappe/frappe` | Git URL for Frappe framework |
| `FRAPPE_BRANCH` | `version-16` | Git branch or tag for Frappe framework |
| `PYTHON_VERSION` | `3.14` | Base Python runtime version |
| `NODE_VERSION` | `24` | Node.js runtime for asset compilation |
| `INSTALL_CHROMIUM` | `true` | Installs `chromium-headless-shell` for PDF/print generation |
| `CACHE_BUST` | `""` | Arbitrary string to invalidate build cache |

---

## 2. GitHub Actions Release Workflow

The release automation in `.github/workflows/release.yml` triggers on version tags (`v*.*.*`).

### Workflow Steps:

1. **Verify Job:**
   - Builds a local `linux/amd64` smoke-test image.
   - Asserts that Frappe core, `assets.json`, and `bench` CLI are valid inside the built container.

2. **Publish Job (Multi-Arch):**
   - Sets up QEMU and Buildx.
   - Authenticates to GitHub Container Registry (`ghcr.io`).
   - Uses `docker/metadata-action` to derive SemVer tags:
     - Tag `v16.3.0` emits `ghcr.io/<repo>:16.3.0`, `:16.3`, `:16`, and `:latest`.
   - Compiles and pushes multi-arch images (`linux/amd64`, `linux/arm64`).
   - Generates and signs **SLSA Provenance Attestations** via `actions/attest-build-provenance`.
