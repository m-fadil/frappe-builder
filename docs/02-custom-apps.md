---
title: Custom Apps and Secret Management
---

# 02 - Custom Apps & Secret Management

Custom Frappe applications are injected at build time using an `apps.json` manifest.

---

## 1. Defining `apps.json` with Multiple Sources & Tokens

Different apps can come from different sources (GitHub public, GitHub private org, GitLab private, Bitbucket, self-hosted git), and each private repo can use its own distinct secret token.

Use variable placeholders (e.g. `${SECRET_NAME}`) directly in the URL:

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  },
  {
    "url": "https://oauth2:${GITHUB_PRIVATE_APP_PAT}@github.com/my-org/my-crm-app.git",
    "branch": "main"
  },
  {
    "url": "https://oauth2:${GITLAB_PAYROLL_TOKEN}@gitlab.com/client-org/payroll-app.git",
    "branch": "v1.2.0"
  },
  {
    "url": "https://${BITBUCKET_USER}:${BITBUCKET_APP_PASS}@bitbucket.org/team/inventory.git",
    "branch": "production"
  }
]
```

---

## 2. GitHub Secrets Mapping

You do **not** need to hardcode token names in the workflow file. The CI/CD workflows (`ci.yml` and `release.yml`) automatically expose the full `${{ toJson(secrets) }}` context to the substitution step.

### Step-by-Step:
1. Choose any environment variable name in `apps.json` (e.g. `${GITHUB_PRIVATE_APP_PAT}`, `${GITLAB_PAYROLL_TOKEN}`).
2. Go to **Repository Settings > Secrets and variables > Actions**.
3. Create a GitHub Secret with the **exact same name**:
   - Secret Name: `GITHUB_PRIVATE_APP_PAT` &rarr; Value: `ghp_xxxx`
   - Secret Name: `GITLAB_PAYROLL_TOKEN` &rarr; Value: `glpat-xxxx`
   - Secret Name: `BITBUCKET_APP_PASS` &rarr; Value: `secretpass`

### How the CI/CD Pipeline Resolves It:
During workflow execution:
1. Every secret in your repository is loaded into the runner environment.
2. `envsubst` scans `apps.json` and replaces all matching placeholders (`${...}`) with their corresponding secret values.
3. The resolved JSON is written to `/tmp/apps.json` and passed into Docker BuildKit via `--secret id=apps_json,src=/tmp/apps.json`.
4. No secrets are ever written to the image layers or Git history.

---

## 3. Alternative: Single Full `APPS_JSON` Secret

If you prefer not to commit `apps.json` to Git at all:
1. Store the entire JSON string in a GitHub Secret named **`APPS_JSON`**.
2. The workflow detects `APPS_JSON` and uses it directly, bypassing the committed `apps.json` file.

---

## 4. Local Build with Multiple Secret Tokens

When building locally on your machine, export the required tokens in your shell before running `envsubst`:

```bash
export GITHUB_PRIVATE_APP_PAT="ghp_xxx"
export GITLAB_PAYROLL_TOKEN="glpat-xxx"
export BITBUCKET_USER="dev-user"
export BITBUCKET_APP_PASS="pass123"

# Substitute tokens into a temporary file
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
