# Yanol Tech — Reusable DevOps Workflows

Shared GitHub Actions workflows for all Yanol Tech projects. Every project
calls these workflows instead of copy-pasting CI/CD config.

## Workflows

### `ci.yml` — Continuous Integration
Runs on every PR and push to `development`. Validates only — never deploys.

**Inputs:**
| Input | Required | Default | Description |
|---|---|---|---|
| `language` | yes | — | `go`, `node`, or `python` |
| `service` | yes | — | `backend`, `frontend`, or `worker` |
| `run_integration` | no | `true` | Run integration tests with ephemeral DB |
| `docker_context` | no | `.` | Docker build context path |

**Steps:** checkout → setup runtime → install deps → format check → lint → typecheck → unit tests → integration tests (ephemeral Postgres + Redis) → Docker build → Trivy scan (critical CVE = fail)

### `staging.yml` — Staging CD
Runs on push to `staging` branch. Builds image, pushes to GHCR, deploys to Dokploy staging.

**Inputs:**
| Input | Required | Default | Description |
|---|---|---|---|
| `project` | yes | — | Project name (e.g. `yano-pms`) |
| `service` | yes | — | Service name (e.g. `backend`) |
| `health_path` | no | `/health` | Health endpoint path |

**Secrets required:** `GHCR_TOKEN`, `DOKPLOY_API_KEY`, `DOKPLOY_STAGING_APP_ID`

**Flow:** checkout → build `ghcr.io/yanol-tech-solution/<project>-<service>:<sha>` → push → Trivy scan → update Dokploy app image → deploy → wait for `done` → health check

### `production.yml` — Production CD
Manual `workflow_dispatch` only. Same flow as staging but with manual approval gate, `cancel-in-progress: false`, longer timeouts, and deployment record in job summary.

**Secrets required:** `GHCR_TOKEN`, `DOKPLOY_API_KEY`, `DOKPLOY_PRODUCTION_APP_ID`

## Usage in a project

```yaml
# .github/workflows/ci.yml (in each project repo)
name: CI
on:
  pull_request:
    branches: [development, staging, production]
  push:
    branches: [development]

jobs:
  ci:
    uses: Yanol-TEch-Solution/devops-workflows/.github/workflows/ci.yml@v1
    with:
      language: go
      service: backend
    secrets: inherit
```

```yaml
# .github/workflows/staging.yml
name: Staging CD
on:
  push:
    branches: [staging]

jobs:
  deploy:
    uses: Yanol-TEch-Solution/devops-workflows/.github/workflows/staging.yml@v1
    with:
      project: yano-pms
      service: backend
    secrets: inherit
```

```yaml
# .github/workflows/production.yml
name: Production CD
on:
  workflow_dispatch:

jobs:
  deploy:
    uses: Yanol-TEch-Solution/devops-workflows/.github/workflows/production.yml@v1
    with:
      project: yano-pms
      service: backend
    secrets: inherit
```

## Tagging

This repo uses `v1`, `v2`, etc. tags. Projects reference `@v1` to get
patch updates automatically. Breaking changes = new major version tag.
