---
title: Custom Apps and Secret Management
---

# 02 - Custom Apps & Secret Management

Custom Frappe applications are injected at build time using an `apps.json` manifest.

---

## The `apps.json` Schema

Place `apps.json` in the root directory:

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
    "url": "https://github.com/frappe/helpdesk",
    "branch": "main"
  }
]
```

### Properties:
- **`url`** *(string, required)*: Git clone URL. Supports HTTPS and embedded token authentication.
- **`branch`** *(string, optional)*: Branch name, tag, or commit hash. Defaults to the repository's default branch.

---

## Private Repositories & BuildKit Secrets

When cloning private repositories, embed credentials directly in the URL:

```json
[
  {
    "url": "https://oauth2:ghp_YOUR_PERSONAL_ACCESS_TOKEN@github.com/your-org/my-private-app.git",
    "branch": "main"
  },
  {
    "url": "https://gitlab-ci-token:YOUR_GITLAB_TOKEN@gitlab.com/your-org/another-app.git",
    "branch": "production"
  }
]
```

### Security Guarantees:
The `Containerfile` consumes `apps.json` exclusively through BuildKit secret mounts:
```dockerfile
RUN --mount=type=secret,id=apps_json,target=/opt/frappe/apps.json,uid=1000,gid=1000 \
  bench init --apps_path=/opt/frappe/apps.json ...
```

1. The secret is mounted into a temporary in-memory tmpfs mount point inside the builder stage.
2. The file is unmounted immediately after `bench init` completes.
3. Neither `apps.json` nor the credentials within it are committed to any intermediate layer or final image metadata.
4. `.git` folders are stripped after installation to further minimize image footprint and sanitize repository history.
