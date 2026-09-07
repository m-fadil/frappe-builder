---
title: Custom Apps and Secret Management
---

# 02 - Custom Apps & Secret Management

Custom Frappe applications are injected at build time using an `apps.json` manifest. Credentials for private repos are supplied separately through a `.netrc` file, so `apps.json` itself never has to carry a token.

---

## 1. Defining `apps.json`

Different apps can come from different sources (GitHub public, GitHub private org, GitLab private, Bitbucket, self-hosted git). URLs stay plain — no embedded credentials required:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  },
  {
    "url": "https://github.com/my-org/my-crm-app.git",
    "branch": "main"
  },
  {
    "url": "https://gitlab.com/client-org/payroll-app.git",
    "branch": "v1.2.0"
  },
  {
    "url": "https://bitbucket.org/team/inventory.git",
    "branch": "production"
  }
]
```

`bench get-app` clones each `url` with the same `git` binary used for `git clone`. Authentication for the private entries above comes from `.netrc`, not the URL — see the next section.

---

## 2. Private Apps via `.netrc` (recommended)

Git's HTTPS transport reads `~/.netrc` automatically and matches entries purely by hostname, so **one `machine` block covers every private `apps.json` entry on that host** — no per-app placeholder bookkeeping.

The `Containerfile` already mounts it as a build secret next to `apps_json`:

```dockerfile
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json,uid=1000,gid=1000 \
  --mount=type=secret,id=netrc,target=/home/frappe/.netrc,uid=1000,gid=1000,mode=0600 \
  ...
```

### Format

See [`example.netrc`](../example.netrc) for GitHub, GitLab, Bitbucket, and self-hosted examples. Minimal shape:

```
machine github.com
login octocat
password ghp_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

- `machine` — exact hostname from the `apps.json` URL (no scheme, no path).
- `login` — required by the netrc format even when a provider ignores the username; some providers use it as a fixed keyword instead of a real account name (see below).
- `password` — the token or app password.

| Provider | `login` convention | `password` |
|---|---|---|
| GitHub | your GitHub username, or `x-access-token` for a GitHub App installation token | Personal Access Token / installation token |
| GitLab | `oauth2` | Personal/Project Access Token |
| Bitbucket Cloud | real workspace/account username | App Password |
| Self-hosted (Gitea/GitLab CE/Forgejo) | per-instance convention, often the token name | Deploy/access token |

> One `machine` entry = one credential per host. If two private repos on the *same* host genuinely need two different tokens, fall back to [Section 4](#4-alternative-embedding-tokens-in-the-url).

### Local Build

```bash
cp example.netrc build.netrc   # build.netrc is gitignored — real tokens go only here
chmod 600 build.netrc

docker build \
  --no-cache \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH=version-16 \
  --secret id=apps_json,src=apps.json \
  --secret id=netrc,src=build.netrc \
  --tag my-org/custom-frappe:16.0.0 \
  --file Containerfile .
```

If `apps.json` has no private entries, drop the `--secret id=netrc` flag entirely — the mount is optional and `bench get-app` simply proceeds without it.

---

## 3. CI/CD: Supplying `apps.json` and `.netrc` from GitHub Secrets

Both `ci.yml` and `release.yml` resolve the same two build secrets before every build:

### `apps.json`
1. Committed as-is; plain URLs need no placeholders for Git auth.
2. An optional **`APPS_JSON`** repository secret can fully replace the committed file (e.g. to add apps without touching the repo). The workflow detects it and bypasses `apps.json`.
3. If neither is available the build proceeds with `[]` (no custom apps).

### `.netrc`
1. Store the entire file content — same format as `example.netrc`, with real tokens — in a repository secret named **`NETRC`**.
   - **Repository Settings > Secrets and variables > Actions > New repository secret**, name `NETRC`, paste the multi-line content.
2. The workflow writes it to `/tmp/netrc` and mounts it via `--secret id=netrc,src=/tmp/netrc`. An unset `NETRC` secret produces an empty file, which is a no-op.

No secrets are ever written to image layers, `docker inspect`, or Git history — both files only ever exist as BuildKit secret mounts or transient runner-local temp files.

> `release.yml`'s *Resolve upstream app revisions* step runs `git ls-remote` directly on the runner (outside the Docker build) to fold upstream commits into `CACHE_BUST`. For that to authenticate against private hosts, the workflow also installs the same content at the runner's `$HOME/.netrc` — one file backs both the host-side `ls-remote` calls and the in-container build.

---

## 4. Alternative: Embedding Tokens in the URL

`.netrc` covers the common case of one credential per host. If a host needs more than one distinct credential (e.g. two private repos with separately scoped tokens), embed a placeholder directly in that app's `url` instead — it takes precedence over `.netrc` for that URL:

```json
{
  "url": "https://oauth2:${GITLAB_PAYROLL_TOKEN}@gitlab.com/client-org/payroll-app.git",
  "branch": "v1.2.0"
}
```

Export the token locally, or set a same-named repository secret in CI — `envsubst` resolves it into `apps.json` using the full `${{ toJson(secrets) }}` context, the same mechanism that resolves `APPS_JSON`/`NETRC`.

```bash
export GITLAB_PAYROLL_TOKEN="glpat-xxx"

# Substitute the token into a temporary file
envsubst < apps.json > /tmp/apps.json

# Build with BuildKit secret mount
docker build \
  --no-cache \
  --build-arg FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg FRAPPE_BRANCH=version-16 \
  --secret id=apps_json,src=/tmp/apps.json \
  --tag my-org/custom-frappe:16.0.0 \
  --file Containerfile .

# Clean up local temporary file
rm /tmp/apps.json
```
