# DevOps Docs — Agent Guidelines

## Secrets: Dokploy resolves Infisical, CI does not

The actual secret flow is simpler than older docs described:

```
Infisical  →  Dokploy native integration  →  container env at deploy time
```

Dokploy apps use `${{vault.infisical-<env>.SECRET_NAME}}` reference syntax in
their env var config. At deploy time Dokploy calls the Infisical API, resolves
those references, and injects real values into the container.

**CI does not fetch app secrets.** GitHub Actions only:
1. Builds Docker images
2. Pushes them to GHCR
3. Calls Dokploy API to update the image tag and trigger deploy

### What goes in GitHub repo secrets

Only these — no Infisical credentials:

- `DOKPLOY_API_KEY`
- `DOKPLOY_STAGING_BACKEND_APP_ID`
- `DOKPLOY_STAGING_CLIENT_APP_ID`
- `DOKPLOY_PRODUCTION_BACKEND_APP_ID`
- `DOKPLOY_PRODUCTION_CLIENT_APP_ID`

### What does NOT go in GitHub repo secrets

- `INFISICAL_CLIENT_ID` — not needed
- `INFISICAL_CLIENT_SECRET` — not needed
- `INFISICAL_TOKEN` — not needed
- `INFISICAL_PROJECT_ID` — not needed
- Any app secret (DB passwords, JWT, Redis, SMTP) — lives in Infisical only

### Rotating a secret

Update the value in Infisical → redeploy the app in Dokploy. No CI change,
no GitHub secret update, no workflow re-run needed.

### Deprecated approach (do not use)

The old pattern of fetching secrets in CI via `Infisical/secrets-action` and
injecting them into Dokploy env is deprecated. It added complexity, exposed
secrets in CI logs, and duplicated what Dokploy already does natively.

## Deployment model

| Env | Build location | Trigger |
|---|---|---|
| Development | Dokploy server (builds from `development` branch) | Push to `development` |
| Staging | GitHub Actions → GHCR | Push to `staging` |
| Production | GitHub Actions → GHCR | Push to `main` |

Production is **not** manual `workflow_dispatch` — it auto-deploys on push to
`main`. Branch protection on `main` is the gate, not a manual button.

## Architecture per project

- Backend and frontend are **separate Dokploy applications** (not combined Compose).
- Database and Redis come from **shared infrastructure** (not project-local containers).
- Frontend Nginx proxies `/api` to the backend container via `BACKEND_HOST` env var.
- GHCR images use `dockerImage` field (not `image`) with `registryId` set to the GHCR registry.
- Development apps use `sourceType: github` with `buildType: dockerfile` and `dockerContextPath` set.

## When migrating a project

1. Create separate backend + frontend Dokploy apps per environment (6 total).
2. Set `buildType: dockerfile` and `dockerContextPath` on GitHub-source apps.
3. Set `dockerImage` + `registryId` on GHCR-source apps.
4. Configure Dokploy env vars with `${{vault.infisical-<env>.*}}` references.
5. Set GitHub repo secrets (DOKPLOY_API_KEY + app IDs only).
6. Add staging + production CD workflows (build → push GHCR → call Dokploy API).
7. No development workflow — Dokploy builds from `development` branch directly.
8. Add `/api/health` endpoint to backend.
9. Configure frontend Nginx to proxy `/api` to `${BACKEND_HOST}:80`.
10. Verify all three environments: frontend HTTP 200 + `/api/health` returns `{"status":"ok","database":"up"}`.
