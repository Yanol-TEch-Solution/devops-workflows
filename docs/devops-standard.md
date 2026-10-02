# Yanol Tech — DevOps Standard (Single Architecture for All Projects)

**Status:** Approved standard — source of truth for all 8 projects and any future project.
**Companion docs:** `devops-architecture.md` (diagrams + global server), `devops-migration-plan.md` (per-project migration).
**Scope:** Standardize Git, Docker, CI/CD, GHCR, Dokploy, shared infrastructure, isolation, secrets, networking, backup, rollback.

> The objective: if a 9th project is added tomorrow, it follows the same
> GitHub → CI/CD → GHCR → Dokploy pattern with zero new architecture decisions.

---

## 0. Core Decisions (locked)

| Decision | Value |
|---|---|
| Deploy model — staging & production | **A: CI builds image → GHCR → Dokploy pulls immutable image.** Server never builds app code for staging/prod. |
| Deploy model — development | **B: Dokploy builds from GitHub `development` branch on the server.** Dev is the only environment where server-side builds happen. |
| Branches | `main` (production), `staging`, `development` (+ `feature/*`, `fix/*`, `hotfix/*`, `release/*`) |
| Image tags | `<commit-sha>` (immutable, primary) + `<env>` alias (convenience, points at latest sha for that env) |
| GHCR org path | `ghcr.io/yanol-tech-solution/<project>` (lowercase, required by GHCR) |
| GitHub org | `Yanol-TEch-Solution` (display) — GHCR path normalized to lowercase `yanol-tech-solution` |
| Shared infra — staging | One shared Postgres, one shared MySQL, one shared Redis. Logical DB + user per project. |
| Shared infra — production | One shared Postgres, one shared MySQL, one shared Redis. Logical DB + user per project. |
| Shared infra — development | Per-project instances via `docker-compose.dev.yml`. No shared dev infra. |
| Isolation | Separate database + separate user + separate credentials + Redis DB index per project. Never shared credentials. |
| CI provider | GitHub Actions (consistent across all repos) |
| Pilot project | `oromia-president-office` |
| Staging data | **Sanitized production snapshot**, refreshed on a schedule. Sanitization pipeline strips PII before load. |
| Branch cutover | **Full rename**: `master`→`main` (set as default), `dev`→`development` in GitHub, Dokploy branch config updated simultaneously, devs notified. One-time disruption, clean end state. |
| DB migrations | Run as a **separate pre-deploy step**, not on container start. Every forward migration has a rollback migration. Prod migrations gated behind manual approval. |
| Deploy concurrency | GitHub Actions `concurrency:` groups per env per project — one deploy at a time, cancel superseded runs. |
| Progressive delivery | Brief parallel-run / canary window before full traffic cutover where the stack supports it. |
| Image scan gate | Trivy critical CVE = **block** prod deploy (not just warn). **Currently relaxed to exit 0** on both staging and production due to 3 critical CVEs in base deps (node-tar, Go stdlib). Re-enable hard gate after fixing CVEs. |
| Deploy credentials | Prefer Dokploy **deploy webhooks** (Dokploy pulls on GHCR push) over CI holding a full-admin API key. If API key used, rotate quarterly and scope where possible. |
| Secrets rotation | DB passwords quarterly, JWT secrets on rotation schedule, GHCR PATs on contributor offboarding. |
| Shared infra blast radius | Resource limits per project connection, connection pool caps, documented shared-infra failure runbook. |
| Dokploy self-backup | Dokploy's own config/volume backed up daily, restore tested. |

---

## 1. Git Branching Standard

### Long-lived branches (every repo)

| Branch | Purpose | Deploy behavior |
|---|---|---|
| `main` | Production release source | CI builds → GHCR → Dokploy pulls (model A). Manual `workflow_dispatch` with required approval. |
| `staging` | Release candidate validation | CI builds → GHCR → Dokploy pulls (model A). Auto-deploys on push. |
| `development` | Active integration / dev work | Dokploy **builds from source on server** (model B) |

### Short-lived branches

- `feature/<ticket>-<slug>` → merge to `development`
- `fix/<ticket>-<slug>` → merge to `development`
- `hotfix/<ticket>-<slug>` → branch from `main`, merge to `main` **and** `development`
- `release/<version>` → branch from `development`, merge to `staging` then `main`

### Rules

- `main` and `staging` are protected: required PR review + required CI checks.
- `development` is protected: required CI checks, PR review recommended.
- Direct pushes to `main`/`staging` are forbidden.
- Preserve Git history — never recreate repos. Migrate branches in place.
- `deploy` branch is **only** for projects whose architecture requires Dokploy to consume a branch (compose-bundle projects). Do not create `deploy` for pure GHCR-pull projects.

### Branch cutover procedure (one-time, per project)

Existing repos use `master` and `dev`. The standard requires `main` (production), `staging`, and `development`. Cutover is a **full rename**, done once per project during its migration:

1. In GitHub: rename `master`→`main` (set as default), `dev`→`development`, create `staging` from `development`.
2. Same moment: update Dokploy app config to watch `development` branch.
3. Update branch protection rules on the new names; remove rules on old names.
4. Notify all developers: `git branch -m master main && git branch -m dev development && git fetch --all && git pull` on each clone.
5. Update any external references (Dokploy webhooks, CI `on:` triggers, documentation links).
6. Verify: push to `development` triggers dev deploy; push to `staging` triggers CI/CD.

GitHub auto-redirects old branch names, so existing clones/PRs keep working temporarily during the transition.

---

## 2. Docker Standard

Every project that builds images (staging/prod path) must have a Dockerfile following:

- **Multi-stage build** (build deps stage → minimal runtime stage).
- **Minimal runtime image** (alpine/distroless/slim where the stack allows).
- **Non-root execution** where practical (`USER app`).
- **`.dockerignore`** present and excludes: `.git`, `node_modules`, `__pycache__`, `.env*`, `*.log`, `dist`, `build`, `coverage`, `.vscode`, `.idea`.
- **Health check** in Dockerfile or via Dokploy `HEALTHCHECK`/health endpoint.
- **Deterministic installs** — pin major versions, use lockfiles (`go.sum`, `package-lock.json`, `poetry.lock`).
- **No secrets baked in** — no `COPY .env`, no hardcoded credentials, no API keys in image layers.
- **Build-time config separate from runtime config** — config injected via env vars at runtime.
- One Dockerfile per buildable service (e.g. `Dockerfile` for backend; frontend may share or have its own).

### Standard repo layout

```text
.github/
  workflows/
    ci.yml              # lint, test, typecheck, build verify, docker build verify, security scan
    staging.yml         # build + push ghcr :<sha> + :staging alias, trigger Dokploy staging
    production.yml      # build + push ghcr :<sha> + :production alias, trigger Dokploy prod (manual gate)
docker/                 # optional build context extras
Dockerfile
docker-compose.dev.yml  # development env (app + per-project db/redis/etc)
docker-compose.yml      # optional: shared base for compose-bundle projects
.dockerignore
.env.example            # non-secret env template, committed
```

Do not force this exact tree where stack conventions differ (e.g. Go monorepo), but keep the file names consistent.

---

## 3. Docker Compose Development Standard

Development uses `docker-compose.dev.yml` per project. Includes only services that project actually needs.

Required properties:
- Persistent dev volumes for DB/Redis data.
- Env vars from `.env` (gitignored) with `.env.example` committed.
- Health checks on each service.
- `depends_on` with `condition: service_healthy`.
- Internal network only — no published DB/Redis ports to the host unless a developer explicitly opts in.
- `restart: unless-stopped` for infra services.
- Dev-friendly config (e.g. Postgres `POSTGRES_HOST_AUTH_METHOD=trust` is acceptable **only** in dev compose).

Example skeleton (adapt per project):

```yaml
services:
  app:
    build: .
    env_file: .env
    ports: ["3000:3000"]
    depends_on:
      postgres: { condition: service_healthy }
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 15s
      timeout: 5s
      retries: 5
  postgres:
    image: postgres:16
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes: ["pgdata:/var/lib/postgresql/data"]
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER}"]
      interval: 10s
      retries: 5
  redis:
    image: redis:7
    volumes: ["redisdata:/data"]
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      retries: 5
volumes:
  pgdata:
  redisdata:
```

---

## 4. CI Pipeline Standard (`.github/workflows/ci.yml`)

Runs on: `pull_request` to `development`, `staging`, `production`; and `push` to `development`.

Mandatory steps (fail fast — pipeline fails if any required step fails):

1. Checkout (with `fetch-depth: 0` for SHA access).
2. Setup language runtime (Go / Node / Python — pinned version).
3. Install dependencies (lockfile-resolved).
4. Formatting check (`gofmt`/`gofumpt`, `prettier --check`, `black --check`).
5. Lint (`golangci-lint`, `eslint`, `ruff`).
6. Type check where applicable (`tsc --noEmit`, `mypy`).
7. Unit tests.
8. Integration tests where applicable.
9. Build verification (compile / build artifact).
10. Docker image build verification (`docker build` — does not push).
11. Security scan (Trivy on the built image; `go vet`; `npm audit` / `pip-audit`).

CI must never deploy. CI only validates. Deployment is the CD workflows' job.

### Concurrency control

Every workflow uses `concurrency:` to prevent racing deploys:

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

One deploy per environment per project at a time. Superseded runs are cancelled.

### CI test database

Integration tests need a DB. Standard: ephemeral Postgres/MySQL **service container** in the CI job, torn down after the run. Never point CI at staging or prod infra.

```yaml
services:
  postgres:
    image: postgres:16
    env:
      POSTGRES_DB: test
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test
    ports: ["5432:5432"]
    options: >-
      --health-cmd pg_isready
      --health-interval 10s
      --health-timeout 5s
      --health-retries 5
```

Redis similarly as a service container where the project uses Redis.

### Reusable workflow contract

All repos reference shared reusable workflows from a central repo
`Yanol-TEch-Solution/devops-workflows` (to be created) so CI/CD is fixed in one
place. New projects call them rather than copy-pasting.

**`ci.yml` inputs:**

| Input | Required | Example | Purpose |
|---|---|---|---|
| `language` | yes | `go` / `node` / `python` | Selects runtime setup + tooling |
| `service` | yes | `backend` / `frontend` / `worker` | Identifies which service in the repo |
| `run_integration` | no (default true) | `true` | Toggle integration tests + service containers |
| `docker_context` | no (default `.`) | `./services/backend` | Build context for docker build verify |

**`staging.yml` / `production.yml` inputs:**

| Input | Required | Example | Purpose |
|---|---|---|---|
| `project` | yes | `yano-pms` | GHCR image name segment |
| `service` | yes | `backend` | GHCR image name segment |
| `dokploy_app_id` | yes (via secret) | `${{ secrets.DOKPLOY_STAGING_APP_ID }}` | Dokploy application to deploy |
| `health_path` | no (default `/health`) | `/healthz` | Health endpoint to poll |

**Caller pattern:**

```yaml
jobs:
  ci:
    uses: Yanol-TEch-Solution/devops-workflows/.github/workflows/ci.yml@v1
    with:
      language: go
      service: backend
    secrets: inherit
  deploy-staging:
    needs: ci
    uses: Yanol-TEch-Solution/devops-workflows/.github/workflows/staging.yml@v1
    with:
      project: yano-pms
      service: backend
    secrets: inherit
```

---

## 5. Staging CD Standard (`.github/workflows/staging.yml`)

Triggers: push to `staging` (after PR merge), or manual `workflow_dispatch`.

```yaml
concurrency:
  group: staging-${{ github.ref }}
  cancel-in-progress: true
```

Flow:

```text
staging branch
  → checkout (full history for SHA)
  → run CI reusable workflow (tests must pass)
  → docker buildx build --tag ghcr.io/yanol-tech-solution/<project>:<sha>
                       --tag ghcr.io/yanol-tech-solution/<project>:staging
  → docker push (both tags)
  → Trivy scan; fail if CRITICAL CVE found (gate, not warning)
  → trigger Dokploy deploy: application.update (set dockerImage=:<sha>) → application.deploy
  → poll Dokploy application.one status until "done" or timeout
  → poll app /health endpoint until healthy or timeout
  → fail the workflow if staging does not become healthy (enables auto-rollback)
```

- Image tag is the commit SHA (immutable). `:staging` is a moving alias pointing at the latest SHA deployed to staging.
- Server does **not** compile staging. It pulls the prebuilt image.
- **Deploy trigger**: CI calls Dokploy API — `application.update` (set `dockerImage` to `:<sha>`) then `application.deploy`. Verified working: deploy completes, status transitions to `done`. Dokploy pulls the image from GHCR using its stored registry credentials.
- Required GitHub secrets: `DOKPLOY_API_KEY`, `DOKPLOY_STAGING_BACKEND_APP_ID`, `DOKPLOY_STAGING_CLIENT_APP_ID`. No Infisical secrets needed — Dokploy resolves vault references at deploy time.

---

## 6. Production CD Standard (`.github/workflows/production.yml`)

Triggers: `workflow_dispatch` (manual) on `production` branch — production is **never** auto-deployed on push. A human approves.

```yaml
concurrency:
  group: production-${{ github.ref }}
  cancel-in-progress: false   # never cancel an in-progress prod deploy
```

Flow:

```text
main branch
  → checkout
  → run CI reusable workflow
  → docker buildx build --tag ghcr.io/yanol-tech-solution/<project>:<sha>
                       --tag ghcr.io/yanol-tech-solution/<project>:production
  → docker push
  → Trivy scan; CRITICAL CVE = block deploy (hard gate)
  → (manual approval gate already passed by workflow_dispatch)
  → run DB migrations as a separate pre-deploy step (manual approval, rollback migration ready)
  → trigger Dokploy deploy: application.update (set dockerImage=:<sha>) → application.deploy
  → poll Dokploy application.one status until "done" or timeout
  → progressive delivery: brief parallel-run / canary window before full traffic cutover (where stack supports)
  → poll app /health endpoint; on failure → Dokploy auto-rollback to previous :<sha>
  → record deployment (repo, commit, run id, image, digest, deploy time) in deployment log
```

- Previous production image is **not** deleted after deploy (kept for rollback).
- Production deployment is always traceable to: repo + commit + Actions run + image + digest.
- `cancel-in-progress: false` — a prod deploy in flight is never cancelled by a new run; the new run queues.
- Required GitHub secrets: `DOKPLOY_API_KEY`, `DOKPLOY_PRODUCTION_BACKEND_APP_ID`, `DOKPLOY_PRODUCTION_CLIENT_APP_ID`. No Infisical secrets needed — Dokploy resolves vault references at deploy time.
- GitHub Environment `production` with required reviewers + deployment branch protection = `production` only.

### DB migration as a pre-deploy step (production)

Migrations never run on container start in production. They run as an explicit, logged, manually-approved step before the new image goes live:

1. CI job runs `migrate up` against prod DB (using a migration service account, not the app's runtime DB user).
2. Migration has a tested `migrate down` (rollback) committed alongside it.
3. If migration fails → deploy aborts, app stays on previous image, on-call alerted.
4. If migration succeeds → proceed to image deploy.
5. On post-deploy health failure → rollback image; **do not** auto-rollback the migration (manual decision, since data may have already been written).

For shared infra: migrations run against the project's own logical DB only. A migration that locks the shared Postgres for >N seconds must be flagged in PR review and run during a maintenance window.

---

## 7. GHCR Naming & Tagging Standard

### Naming

```text
ghcr.io/yanol-tech-solution/<project>-<service>
```

Examples:
- `ghcr.io/yanol-tech-solution/yano-pms-backend`
- `ghcr.io/yanol-tech-solution/yanol-website-frontend`
- `ghcr.io/yanol-tech-solution/oromia-president-office`

### Tags

| Tag | Type | Purpose |
|---|---|---|
| `<commit-sha>` | immutable | Primary, traceable. Every deploy references this. |
| `<branch>` | moving | Convenience only (`staging`, `production`). Points at latest SHA deployed to that env. |
| `v<semver>` | immutable | Release tags from `release/*` merges. |
| `latest` | moving | **Not relied on for deploys.** May exist for dev convenience only. |

**Hard rule:** every deployed production image must be referenced by its `<commit-sha>` tag (and ideally `@sha256:<digest>` pin). Never deploy `:latest` or `:production` alone without the SHA record.

### Registry auth

- Dokploy authenticates to GHCR with a PAT (stored in Dokploy registry config) that has `read:packages` for `yanol-tech-solution`.
- CI authenticates with `GITHUB_TOKEN` (automatic) scoped `packages:write`.

---

## 8. Dokploy Configuration Standard

### Project naming

- One Dokploy **Project** per product: `yanol-pms`, `yanol-website`, `oromia-president-office`, `emahus-hosting`, `gelan-pms`, `yanet-primary-hospital`, `yanet-general-hospital`, `medischedule`, `qirb-alga`.
- Project name = lowercased, hyphenated, matches GitHub repo name.

### Environments per project

Every project gets three Dokploy environments: `development`, `staging`, `production`.

| Env | Source | Build location |
|---|---|---|
| development | GitHub `development` branch | **Server (Dokploy builds)** |
| staging | GHCR image `:<sha>` | CI (off-server) |
| production | GHCR image `:<sha>` | CI (off-server) |

### Application naming

`<project>-<service>-<env>` e.g. `yanol-pms-backend-staging`. Avoid random suffixes where possible (current apps have random `appName` like `app-navigate-bluetooth-array-vgkm2j` — keep as internal appName but set display `name` to the standard).

### Domains

Standard subdomain pattern (per `devops-infrastructure-plan.md` §4):

```text
<project>.yanoltech.com                       production
<project>-staging.yanoltech.com               staging
<project>-dev.yanoltech.com                   development (if exposed)
api.<project>.yanoltech.com                   production API
api-staging.<project>.yanoltech.com           staging API
```

All proxied through Cloudflare → Traefik (Dokploy built-in). TLS via Traefik/Cloudflare.

### Health checks

Every application sets in Dokploy:
- `healthCheckPath`: `/health` (or stack-appropriate)
- `healthCheckSwarm`: enabled
- Dokploy must be able to determine deployment health and auto-rollback on failure.

### Restart policy

`unless-stopped` for all app services.

### Persistent volumes

Only for state the app legitimately owns (uploads cache, etc.). DB/Redis state lives in shared infra containers, not app volumes.

### Networks

Each project's apps join:
- `yanol-staging-net` (staging apps → staging infra)
- `yanol-prod-net` (prod apps → prod infra)
- Dev apps join a per-project dev network.

### Registry authentication

One GHCR registry entry in Dokploy (`ghcr.io`) with the read PAT. All staging/prod apps reference it.

### Deployment triggers

- Staging: Dokploy webhook triggered by GitHub Actions after image push (or Actions calls Dokploy deploy API directly).
- Production: Actions calls Dokploy deploy API on manual `workflow_dispatch`.
- Development: Dokploy watches `development` branch via GitHub integration; auto-deploys on push.

### Explicit per-project declaration

For each project, the migration plan must record:
- Branch Dokploy watches (per env)
- Whether Dokploy builds locally (dev: yes; staging/prod: no)
- Whether Dokploy pulls GHCR (staging/prod: yes; dev: no)
- What triggers deployment
- What artifact is deployed (image:sha / branch HEAD)

No project leaves this ambiguous.

---

## 9. Shared Infrastructure Architecture

### Staging (one set, shared by all staging apps)

```text
yanol-staging-postgres   (postgres:16)   network: yanol-staging-net
yanol-staging-mysql      (mysql:8)       network: yanol-staging-net
yanol-staging-redis      (redis:7)       network: yanol-staging-net
```

### Production (one set, shared by all prod apps)

```text
yanol-prod-postgres      (postgres:16)   network: yanol-prod-net
yanol-prod-mysql         (mysql:8)       network: yanol-prod-net
yanol-prod-redis         (redis:7)       network: yanol-prod-net
```

### Development

No shared dev infra. Each project runs its own Postgres/MySQL/Redis via `docker-compose.dev.yml` on the developer's machine (or Coder workspace). This keeps dev fully self-contained and offline-capable.

### Provisioning a new project on shared infra

For each new project, on **both** staging and prod infra:

1. Create database: `CREATE DATABASE <project>;`
2. Create user: `CREATE USER <project>_user WITH PASSWORD '<random>';`
3. Grant: `GRANT ALL ON DATABASE <project> TO <project>_user;`
4. Redis: assign a dedicated DB index (e.g. project #N → `redis-cli SELECT N`).
5. Store credentials in Dokploy env vars for that project's app, **never** in Git.

---

## 10. Database Isolation Model

```text
Production Postgres (shared container)
  ├── yanol_pms          (user: yanol_pms_user)
  ├── yanol_website      (user: yanol_website_user)
  ├── oromia_president   (user: oromia_president_user)
  ├── emahus             (user: emahus_user)
  └── ...

Production MySQL (shared container)
  ├── yanol_pms
  ├── yanol_website
  └── ...

Production Redis (shared container)
  ├── DB 0  → reserved
  ├── DB 1  → yanol_pms
  ├── DB 2  → yanol_website
  └── ...
```

Staging mirrors this on the staging infra with separate credentials.

### Hard rules

- Project A's app credentials **cannot** connect to Project B's database.
- Staging credentials **cannot** authenticate to production infra.
- Dev credentials **cannot** authenticate to staging or prod infra.
- Each project's `DATABASE_URL` is set per-environment in Dokploy env vars, pointing only to that project's logical DB.

---

## 11. Redis Isolation Model

- One Redis instance per env (staging, production).
- Isolation by **DB index** (Redis logical database 0–15).
- Each project assigned a fixed index, recorded in the migration plan.
- Password shared per Redis instance (set in Dokploy env), but app uses `redis://:<pass>@<host>:6379/<index>`.
- Dev: per-project Redis in `docker-compose.dev.yml`, index 0.

---

## 12. Environment Variables & Secrets Model

### Non-secret configuration (env vars)

| Env | Where stored | Committed to Git? |
|---|---|---|
| Development | `.env` (gitignored) + `.env.example` (committed, no secrets) | No secrets |
| Staging | Dokploy env vars using `${{vault.infisical-staging.*}}` references | No |
| Production | Dokploy env vars using `${{vault.infisical-prod.*}}` references | No |

### Rules

- Never commit secrets. `.gitignore` must include `.env`, `*.env`, `!*.env.example`.
- Never put secrets in Dockerfiles or images.
- Never reuse prod `.env` in staging or dev.
- Each project's secrets scoped to that project's Infisical project + Dokploy apps only.
- All app secrets live in Infisical. Dokploy resolves them at deploy time via `${{vault...}}` references — CI never touches app secrets.
- The only GitHub repo secrets are `DOKPLOY_API_KEY` and `DOKPLOY_*_APP_ID` values (infrastructure IDs, not app secrets).
- Human/admin credentials (Cloudflare, mailbox, registrar, SSH, Dokploy admin, UptimeRobot, Telegram bot token) live in Bitwarden (§12a), never in Git or docs.

### Required env vars per service (standard names)

```text
NODE_ENV / GO_ENV / APP_ENV
DATABASE_URL
REDIS_URL
JWT_SECRET
SENTRY_DSN
POSTHOG_KEY
POSTHOG_HOST
APP_PORT
HEALTH_PATH=/health
```

---

## 12a. Credential Management Standard (Infisical + Bitwarden)

The platform uses two credential stores, each for a distinct purpose:

```text
┌─────────────────────────────────────────────────────────────┐
│  Infisical  —  machine/application secrets                  │
│  (DB passwords, JWT, Redis, PostHog keys, GHCR tokens,      │
│   Dokploy API keys, SMTP, S3 backup keys)                   │
│                                                             │
│  Sources:  Infisical project per Yanol project              │
│  Sinks:    → Dokploy env vars (via Infisical sync)          │
│            → GitHub Actions secrets (via Infisical CLI)     │
│            → docker-compose.dev.yml .env (via Infisical CLI)│
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Bitwarden  —  human/admin credentials                      │
│  (Cloudflare, shared mailbox, domain registrar, server SSH, │
│   Dokploy admin login, UptimeRobot, Telegram bot token,     │
│   Infisical admin login, GHCR admin PAT)                    │
│                                                             │
│  Shared vault: "Yanol Tech DevOps"                          │
│  Access: named team members only, 2FA required              │
└─────────────────────────────────────────────────────────────┘
```

### Infisical — machine/application secrets

**Deployment:** Infisical Cloud (managed free tier for small teams). Self-hosting requires MongoDB + Redis + the Infisical app — too much RAM on a VPS already running 8 projects + PostHog + Netdata. If the team outgrows the free tier, self-host on a separate small VPS.

**Structure:**

```text
Infisical Organization: Yanol Tech
  ├── Project: yanol-pms
  │     ├── Env: development   (dev secrets)
  │     ├── Env: staging       (staging secrets)
  │     └── Env: production    (prod secrets)
  ├── Project: yanol-website
  │     ├── Env: development
  │     ├── Env: staging
  │     └── Env: production
  ├── Project: oromia-president-office
  │     └── ...
  ├── Project: platform-infrastructure
  │     ├── Env: staging       (shared staging DB/Redis passwords)
  │     └── Env: production    (shared prod DB/Redis passwords)
  └── ... (one project per Yanol project)
```

- One Infisical project per Yanol project, with three environments each (development/staging/production).
- A separate `platform-infrastructure` project holds shared infra credentials (shared DB/Redis passwords, S3 backup keys, Dokploy API key, GHCR PAT).
- Dokploy connects to Infisical and resolves `${{vault.infisical-<env>.SECRET_NAME}}` references at deploy time. No service tokens or machine identities needed in CI.

**Secret flow to Dokploy (actual, in use):**

Dokploy has a native Infisical integration. App env vars use `${{vault.infisical-<env>.SECRET_NAME}}` reference syntax. Dokploy resolves these at deploy time — no CI involvement needed for secrets.

```text
Dokploy app env var:
  DB_HOST=${{vault.infisical-prod.DB_HOST}}
  DB_PASSWORD=${{vault.infisical-prod.DB_PASSWORD}}
  JWT_SECRET=${{vault.infisical-prod.JWT_SECRET}}

At deploy time:
  Dokploy → Infisical API → resolves vault references → injects real values into container env
```

This means:
- CI does **not** need Infisical credentials. CI only builds images and calls Dokploy deploy API.
- CI does **not** fetch secrets or pass them to Dokploy.
- Secrets are never in GitHub Actions, never in workflow logs, never in workflow YAML.
- The only GitHub repo secrets needed are: `DOKPLOY_API_KEY` and the `DOKPLOY_*_APP_ID` values.
- Rotating a secret = update it in Infisical → redeploy the app in Dokploy. No CI change needed.

**Secret flow to GitHub Actions:**

CI does **not** fetch app secrets from Infisical. CI only needs:
- `DOKPLOY_API_KEY` — to call Dokploy deploy API
- `DOKPLOY_STAGING_BACKEND_APP_ID`, `DOKPLOY_STAGING_CLIENT_APP_ID` — staging app IDs
- `DOKPLOY_PRODUCTION_BACKEND_APP_ID`, `DOKPLOY_PRODUCTION_CLIENT_APP_ID` — production app IDs

These are non-secret infrastructure IDs (except the API key). No `INFISICAL_CLIENT_ID`, `INFISICAL_CLIENT_SECRET`, or `INFISICAL_TOKEN` needed in GitHub secrets.

The old approach (Infisical CLI in CI, fetching secrets and injecting them into Dokploy env) is **deprecated**. It added complexity, exposed secrets in CI logs, and duplicated what Dokploy already does natively.

**Secret flow to local dev:**

Developers run `infisical secrets pull --env=development` in the project root to generate `.env` for `docker-compose.dev.yml`. No manual secret sharing, no `.env` files sent via Slack.

### Bitwarden — human/admin credentials

**Deployment:** Bitwarden Cloud (managed) or self-hosted Vaultwarden on a separate small VPS. Cloud is simplest for a small team.

**Structure:**

```text
Bitwarden Organization: Yanol Tech
  ├── Vault: DevOps Platform
  │     ├── Cloudflare account
  │     ├── Shared mailbox (development@yanoltech.com)
  │     ├── Domain registrar (yegarahosting)
  │     ├── Server SSH root key
  │     ├── Dokploy admin login
  │     ├── UptimeRobot account
  │     ├── Telegram bot token (alerts)
  │     ├── Infisical admin login
  │     └── GHCR admin PAT
  └── Vault: Per-Project (optional, for project-specific admin creds)
```

- 2FA required on every Bitwarden account.
- Access granted/revoked on onboarding/offboarding (ties to §19 onboarding/offboarding in the original plan).
- The plaintext credentials currently in `devops-implementation-tracker.md` §1 must be **moved to Bitwarden and removed from the doc** as the first action of Phase 0.

### What lives where (summary)

| Credential | Store | Accessed by |
|---|---|---|
| DB passwords (per project per env) | Infisical | Dokploy (vault references at deploy time), dev (CLI) |
| Redis passwords | Infisical | Dokploy (vault references), dev (CLI) |
| JWT secrets | Infisical | Dokploy (vault references), dev (CLI) |
| PostHog project keys | Infisical | Dokploy (vault references), dev (CLI) |
| GHCR PAT (Dokploy read) | Dokploy registry config | Dokploy |
| GHCR PAT (CI write) | Not needed — CI uses built-in `GITHUB_TOKEN` | GitHub Actions |
| Dokploy API key | GitHub Actions secrets | CI (to call deploy API) |
| Dokploy app IDs | GitHub Actions secrets | CI (to target deploy) |
| S3 backup access keys | Infisical (platform-infra project) | Backup job in Dokploy |
| SMTP passwords | Infisical | Dokploy (vault references), dev (CLI) |
| Cloudflare account | Bitwarden | humans |
| Shared mailbox | Bitwarden | humans |
| Domain registrar | Bitwarden | humans |
| Server SSH root key | Bitwarden | humans |
| Dokploy admin login | Bitwarden | humans |
| UptimeRobot account | Bitwarden | humans |
| Telegram bot token | Bitwarden (master copy) + Infisical (platform-infra, for Netdata/UptimeRobot integrations) | humans + Netdata/UptimeRobot |
| Infisical admin login | Bitwarden | humans |

### Security rules

- Never commit secrets to Git (enforced by `.gitignore` + pre-commit secret scanning).
- Never put secrets in Dockerfiles or images.
- Never share secrets via Slack/email/chat — share via Infisical or Bitwarden.
- Infisical service tokens are scoped per project — a token for project A cannot read project B's secrets.
- Bitwarden vault access is reviewed on offboarding (§19 of original plan).
- Infisical audit log is reviewed monthly for unexpected access.
- The plaintext credentials in `devops-implementation-tracker.md` §1 are a **known violation** to be fixed in Phase 0 step 1.

---

## 13. Networking Model

```text
Internet → Cloudflare (DNS, WAF, TLS, DDoS) → Traefik (Dokploy) → app containers
```

- DB/Redis containers: **no public ports**. Reachable only from `yanol-staging-net` / `yanol-prod-net`.
- App containers: only the ports Traefik routes to. No direct public app ports.
- Dev infra: localhost-only or internal compose network.
- Each app joins only the network of its own environment. Cross-env network access is forbidden.

### Isolation reality check

Docker networks alone do **not** prevent an app from connecting to another project's DB if it somehow has that project's credentials — on a single Docker host, networks are about reachability, not cryptographic isolation. Real isolation is therefore **credential-based**:

- Each project's DB user is scoped (`GRANT` only on that project's database; `REVOKE` on others; no superuser).
- DB users are restricted to the project's own logical DB — a user created for project A literally cannot `USE`/`\connect` project B's database because it lacks privileges.
- `DATABASE_URL` per app points only at that project's DB.
- Acceptance: if an attacker compromises project A's app and extracts its env vars, they get project A's data — not project B's. That is the threat model. Full network-level isolation (separate Docker hosts per project) is out of scope for this single-server platform.

---

## 14. Backup Strategy

### Current state

No formal backup strategy implemented yet (per tracker §2). This standard defines the required target.

### Required (minimum, all shared DBs)

- Automated daily logical backup (`pg_dump` / `mysqldump`) + WAL/point-in-time for Postgres where supported.
- Retention: daily ×7, weekly ×4, monthly ×6.
- Off-server storage: **Cloudflare R2** (S3-compatible, no egress fees, same Cloudflare account as DNS/edge). Bucket: `yanol-backups`.
- Restore test: scheduled monthly, result recorded.

### Critical systems (additional)

- Postgres point-in-time recovery (WAL archiving).
- Defined RPO/RTO per project (recorded in migration plan).
- Replication where business criticality warrants it.

### Dokploy self-backup (mandatory)

Dokploy stores all app definitions, env vars, domain mappings, registry creds, and deployment history. Losing it = losing the entire deployment configuration for 8 projects. Back up:

- Dokploy's data volume / config directory daily to off-server storage.
- Restore test: rebuild a Dokploy instance from backup on a throwaway host, verify apps are defined.

### Single-VPS disaster recovery

The entire platform runs on one VPS. If it dies, all 8 projects go down. Required DR artifacts:

- **Server rebuild runbook**: provision new VPS → install Dokploy → restore Dokploy config backup → restore DB backups from off-server storage → pull latest GHCR images → bring apps online.
- **Recovery sources**: GHCR (images, immutable), off-server DB backups, Dokploy config backup, Cloudflare DNS (unchanged).
- **RTO target**: documented per business criticality (target: 4 hours for critical apps).
- **RPO target**: 24 hours max (daily backups), 1 hour for critical systems with WAL archiving.
- **Test**: schedule a full DR drill annually (or after major infra changes).

### Rule

A backup that has never been restored is not a reliable backup. Restore tests are scheduled, not assumed.

---

## 14a. Shared Infrastructure Blast Radius

Consolidating 8 projects onto shared Postgres/MySQL/Redis increases efficiency but creates a larger failure domain: one shared DB crash affects all projects on that environment.

### Mitigations

- **Resource limits**: each shared infra container gets CPU/memory limits in Dokploy so one project's query load cannot starve the others or OOM the DB.
- **Connection pool caps**: each project's app uses a bounded connection pool (e.g. max 20 conns). Total across all projects must stay under Postgres `max_connections` with headroom.
- **Per-project DB user with connection limit**: `ALTER USER <project>_user CONNECTION LIMIT 25;` so a runaway app cannot exhaust the shared server's connections.
- **Monitoring**: alert on shared DB CPU > 80%, connection count > 80% of max, disk > 80%, replication lag.
- **Shared-infra failure runbook**: documented steps for recovering a crashed shared Postgres/MySQL/Redis, including which projects are affected and how to fail over or restore.
- **Future option**: if a project grows to warrant it, split it off onto its own dedicated DB instance (document the trigger threshold, e.g. sustained > 50% of shared DB CPU).

---

## 14b. VPS Resource Constraints (7.6GB RAM, 4 cores)

**Current VPS state (verified 2026-09-01):**

| Resource | Total | Used | Available |
|---|---|---|---|
| RAM | 7.6 GB | 5.0 GB | 2.1 GB |
| Swap | 4.0 GB | 2.5 GB | 1.5 GB |
| CPU | 4 cores | — | — |

The server is **already memory-constrained** — 2.5GB of swap is actively in use, meaning the kernel is swapping under current load.

### What fits on this VPS

| Component | Est. RAM | Status |
|---|---|---|
| Dokploy + Traefik | ~500MB | already running |
| 8 projects' apps (current per-project DBs) | ~4.5GB | already running (this is the 5GB used) |
| Shared infra (6 containers replacing per-project DBs) | ~1.5GB | **net savings** — replaces ~3GB of per-project DBs |
| Netdata | ~100MB | new |
| PostHog | 0 | **PostHog Cloud — not on VPS** |

### Resource strategy for 7.6GB

1. **Shared infra consolidation is mandatory, not optional.** Replacing per-project DB containers with shared ones is what frees the RAM needed for the standardized architecture. Without consolidation, the VPS cannot support the standard.
2. **PostHog Cloud** (not self-hosted) — confirmed. Self-hosted PostHog's 4GB+ requirement is incompatible with this VPS.
3. **Netdata is lightweight** (~100MB) — fits.
4. **No additional heavy services on this VPS.** Prometheus/Grafana/Loki (full observability stack) would need 1-2GB — defer until VPS upgrade or use managed alternatives.
5. **Monitor RAM closely** after consolidation. If swap usage doesn't drop after migrating to shared DBs, investigate per-app memory usage and set Docker memory limits.
6. **Set Docker memory limits** on every container (app + infra) so one runaway container cannot OOM the server. This is now **mandatory** on this VPS, not just recommended.

### When to upgrade

Upgrade the VPS (to 16GB+) when **any** of these become true:
- Swap usage stays above 1GB after consolidation.
- A project needs its own dedicated DB instance (split from shared).
- Full observability stack (Prometheus/Grafana/Loki) is needed on-server.
- PostHog self-hosting becomes a requirement (data residency, cost at scale).
- A 9th+ project is added and RAM headroom drops below 1GB.

---

## 15. Rollback Procedure

### Automatic (Dokploy)

- On deploy, Dokploy starts new container, runs health check.
- If unhealthy within timeout → auto-rollback to previous image.
- Previous production image is **not** deleted post-deploy.

### Manual rollback

1. Identify last known-good `<commit-sha>` from the deployment log (or `gh run list` / GHCR package history).
2. Trigger `production.yml` `workflow_dispatch` with `ref=<known-good-sha>` — or call Dokploy API directly with the known-good image tag.
3. Verify health passes.
4. Record rollback in deployment log with reason.

### What must never happen

- Rolling back by re-pushing `:latest` or `:production` tags to an old image (ambiguous).
- Deleting the current image before rollback is confirmed healthy.

---

## 16. Migration Strategy (high-level — details in `devops-migration-plan.md`)

Do not change all 8 projects at once. Order:

1. Build the standard + reusable templates (this doc + reusable workflows repo).
2. Stand up shared staging + prod infra on the server.
3. Migrate **pilot: oromia-president-office** end-to-end. Validate full chain.
4. Migrate remaining projects one at a time, in the order in the migration plan.
5. After each project: run the validation checklist. Do not proceed if any production problem is unresolved.
6. Final: remove now-unused per-project DB/Redis containers (only after verifying unused), add monitoring, document.

---

## 17. Preserve Application Functionality

This is infrastructure standardization, **not** an application rewrite.

Do **not** change: business logic, APIs, DB schemas (unless the migration strictly requires a DB/user rename), auth behavior, UI, product behavior.

If app code must change to make the standardized deploy work, document exactly why in the per-project migration report.

---

## 18. Documentation Requirements

Per project (in its own repo `docs/deployment.md`):
- Architecture, environments, branching, Docker, CI, CD, GHCR image, Dokploy config, DB/Redis deps, env vars, required secrets, deploy procedure, rollback procedure, troubleshooting.

Global (this directory):
- `devops-standard.md` (this file)
- `devops-architecture.md` (global server + diagrams)
- `devops-migration-plan.md` (per-project migration + validation)

---

## 18a. Staging Data Strategy

Staging must closely reproduce production (per §1). Staging data comes from **sanitized production snapshots**, refreshed on a schedule.

### Process

1. Scheduled job (e.g. weekly) dumps each project's production logical DB.
2. Sanitization pipeline strips PII before load: emails → `user+test@yanoltech.com`, passwords → hashed test values, tokens/secrets → placeholders, phone numbers → masked, payment data → removed or tokenized.
3. Load sanitized dump into the project's staging logical DB on shared staging infra.
4. Record sanitization run + checksum in a log.

### Rules

- Never copy production secrets, real passwords, real payment data, or real PII into staging.
- Sanitization is automated, not manual — a script per project committed to its repo (`scripts/sanitize-staging.sh` or equivalent).
- Staging credentials cannot read production dumps directly; the dump→sanitize→load pipeline uses a dedicated migration service account.
- If a project's data is too sensitive or large for snapshotting, document an exception and use synthetic seed data instead.

---

## 18b. Secrets Rotation

Secrets rotate on a schedule. Infisical holds the current value; updating it in Infisical propagates to Dokploy (via sync) and CI (via pull on next run).

| Secret | Frequency | Trigger |
|---|---|---|
| DB passwords (per project per env) | Quarterly | Scheduled |
| JWT secrets | On rotation schedule or security incident | Manual + scheduled |
| GHCR PAT (Dokploy read) | On contributor offboarding + every 6 months | Manual |
| Dokploy API key (if used in CI) | Quarterly | Scheduled |
| Cloudflare API tokens | Every 6 months | Scheduled |
| SMTP passwords | Annually | Scheduled |
| Infisical machine client secret | Every 6 months | Scheduled |
| S3 backup access keys | Annually | Scheduled |

### Procedure (Infisical-managed secrets)

1. Generate new secret.
2. Update in Infisical (project → env).
3. Infisical sync propagates to Dokploy env vars automatically (or CI pulls on next run).
4. Redeploy affected apps so they pick up the new value (Dokploy sync may trigger auto-redeploy; verify).
5. Verify health post-rotation (UptimeRobot + Netdata).
6. Revoke old secret only after all apps confirmed using the new one.
7. Infisical audit log records who changed what and when.

### Procedure (Bitwarden-managed human creds)

1. Generate new credential.
2. Update in Bitwarden vault item.
3. Update in any service that uses it (e.g. Cloudflare token → update Cloudflare + any integration).
4. Revoke old credential.
5. Bitwarden maintains item history.

### Future automation

Infisical supports rotation templates for common secret types (database passwords, API keys). When the manual quarterly rotation across 8 projects × 3 envs becomes error-prone, automate via Infisical rotation + a scheduled GitHub Action that triggers redeploy after rotation.

---

## 18c. Pipeline-Failure Observability

Alerting covers app/infra health (standard §14a, plan §alerting). The deploy pipeline itself also needs alerts — a silently failing `production` workflow is a real risk.

### Alert on

| Event | Severity | Channel |
|---|---|---|
| `production.yml` workflow failure | CRITICAL | Telegram + email |
| `staging.yml` workflow failure | WARNING | Telegram |
| `ci.yml` failure on `production`/`staging` branch | WARNING | Telegram |
| Dokploy deploy API call non-200 | CRITICAL | Telegram + email |
| GHCR push failure | CRITICAL | Telegram + email |
| No successful prod deploy in N days for a project with commits | WARNING | Telegram |
| Image scan found critical CVE (blocked deploy) | INFO | email |

### Implementation

GitHub Actions `on:` `workflow_run` or a separate monitoring workflow that checks `gh run list` for failures and posts to Telegram. Alternatively, GitHub's native email notifications for workflow failures on protected branches.

---

## 18d. Incident Response

### Severity model

| Severity | Meaning | Response |
|---|---|---|
| CRITICAL | Production down, data loss risk, security breach | Immediate, all hands |
| WARNING | Degraded service, deploy failed but auto-rollback succeeded | Investigate within 1 hour |
| INFO | Operational notice (e.g. image scan blocked a deploy) | Review next business day |

### Process

1. **Detect**: alert fires (Telegram/email) or user reports.
2. **Acknowledge**: on-call confirms in a dedicated incident channel.
3. **Assess severity**: CRITICAL → page all relevant; WARNING → on-call handles.
4. **Mitigate**: rollback to known-good image (standard §15), scale up, or block traffic via Cloudflare.
5. **Resolve**: confirm health checks pass, monitoring normal.
6. **Postmortem** (mandatory for CRITICAL, recommended for WARNING): written within 48 hours, covers timeline, root cause, action items, owner, due date. Stored in `docs/incidents/`.

### On-call

- One primary on-call, one secondary.
- Rotation weekly.
- On-call schedule + contact info in a shared location (not in Git).

---

## 19. PostHog Standard (Product Analytics)

PostHog is the platform's product analytics tool — for **user/product behavior only**. It is explicitly **not** infrastructure monitoring, error tracking, or log aggregation. Boundary:

```text
PostHog  → user/product behavior (sessions, events, funnels, retention, feature flags, A/B tests)
Sentry   → application errors (future — not in this standard yet)
Prometheus → infrastructure metrics (future — not in this standard yet)
Logs     → detailed events (future — not in this standard yet)
```

### Deployment

- **PostHog Cloud (managed)** — not self-hosted. The VPS has 7.6GB RAM with 5GB already in use + 2.5GB swap active. Self-hosted PostHog requires 4GB+ for its own stack (ClickHouse + Postgres + Redis + Kafka + 7 containers) — does not fit.
- PostHog Cloud free tier covers ~1M events/month, sufficient for current scale.
- No VPS resources consumed. No `analytics.yanoltech.com` domain needed (events go to `https://app.posthog.com` or EU cloud).
- No backup needed — PostHog Cloud manages its own data.
- `POSTHOG_HOST` env var points to `https://app.posthog.com` (or `https://eu.posthog.com` if EU region chosen).

### Project integration

Every project's app sends product analytics events to PostHog. Standard:

1. PostHog project created per product (one PostHog project per Yanol project — isolation by project key, not shared key).
2. Each app gets `POSTHOG_KEY` and `POSTHOG_HOST` env vars (set in Dokploy env vars per environment).
3. Events tagged with `env` property (`development` / `staging` / `production`) so prod data isn't polluted by dev/staging traffic.
4. Events tagged with `app_version` = `<commit-sha>` so product behavior maps to a specific deploy.
5. PII handling: PostHog captures whatever the app sends. Each project is responsible for not sending raw PII to PostHog (hash or pseudonymize user identifiers; document per project).

### Feature flags

PostHog feature flags are the platform's standard feature-flag mechanism. Rules:

- Flags defined per PostHog project.
- Flag keys: `snake_case`, prefixed with project short name where cross-project clarity matters (e.g. `pms_new_checkout`).
- Flag evaluated server-side where possible (avoids client-side flicker + keeps flag logic server-controlled).
- Document active flags in each project's `docs/deployment.md`.

### A/B testing

PostHog experiments are the standard A/B testing mechanism. Results tracked in PostHog; experiment definitions documented per project.

### Environments

| Env | PostHog behavior |
|---|---|
| development | Sends events with `env=development`. May use a separate PostHog project key to keep dev noise out of prod analytics. |
| staging | Sends events with `env=staging`. Same PostHog instance, filtered by env property. |
| production | Sends events with `env=production`. Primary analytics data. |

### What PostHog does NOT cover

PostHog is product analytics only. Infrastructure monitoring and alerting are covered by the interim observability layer (§19a). The remaining gaps (queryable historical metrics, log search, tracing, SLOs) are tracked in §20.

---

## 19a. Interim Observability & Alerting (UptimeRobot + Netdata + Telegram)

The platform needs to know when something breaks **now**, not after a full Prometheus/Grafana/Loki stack is built. This interim layer covers the biggest gaps with minimal setup and zero cost. It is the standard until a full observability stack is introduced.

### Stack

| Tool | Role | Where | Cost |
|---|---|---|---|
| **UptimeRobot** | external uptime + TLS expiry — pings each project's `/health` from outside the server | external (managed) | free |
| **Netdata** | infra + container + DB health — auto-discovers Docker containers, Postgres, Redis | one container on the VPS | free |
| **Telegram bot** | receives alerts from both UptimeRobot and Netdata | external | free |

### Why both UptimeRobot and Netdata

- Netdata runs **on the VPS** — it catches DB crashes, disk full, container died, high CPU/RAM. But if the whole VPS dies, Netdata dies with it and sends nothing.
- UptimeRobot runs **outside the VPS** — it catches "the server is unreachable" and "TLS expired" and "`/health` is returning 500." It alerts even when the VPS is dead.
- You need both. Neither alone is sufficient.

### UptimeRobot configuration

For each project, one monitor:
- Type: HTTP(s)
- URL: `https://<project>.yanoltech.com/health` (the standard health endpoint)
- Interval: 5 minutes
- Alert when: down, TLS expired, response > 30s
- Alert channel: Telegram bot

Also add monitors for:
- `https://dokploy.yanoltech.com` (Dokploy itself)
- `https://analytics.yanoltech.com` (PostHog, once deployed)
- Each shared infra container's health (via a small `/health` proxy endpoint or Dokploy's built-in health check exposed internally — if not externally reachable, monitor the apps that depend on it and rely on Netdata for the DB itself)

Total: ~10 monitors for 8 projects + platform services.

### Netdata configuration

Deploy as a Docker container on the VPS:

```yaml
# netdata (deploy via Dokploy Compose or docker run)
services:
  netdata:
    image: netdata/netdata
    pid: host
    network_mode: host
    restart: unless-stopped
    cap_add: [SYS_PTRACE, SYS_ADMIN]
    security_opt: [apparmor:unconfined]
    volumes:
      - netdataconfig:/etc/netdata
      - netdatalib:/var/lib/netdata
      - netdatacache:/var/cache/netdata
      - /etc/passwd:/host/etc/passwd:ro
      - /etc/group:/host/etc/group:ro
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /etc/os-release:/host/etc/os-release:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
volumes:
  netdataconfig:
  netdatalib:
  netdatacache:
```

Netdata auto-discovers:
- All Docker containers (per-container CPU/mem/net)
- Postgres (if connection configured)
- Redis (if connection configured)
- Disk usage, RAM, CPU, network per host

### Alert rules (Netdata — built-in, enable these)

| Alert | Trigger | Severity | Channel |
|---|---|---|--- |
| disk space | `disk_space.usage > 90%` for 5 min | CRITICAL | Telegram |
| disk space | `disk_space.usage > 80%` for 10 min | WARNING | Telegram |
| RAM | `ram.usage > 95%` for 5 min | CRITICAL | Telegram |
| RAM | `ram.usage > 85%` for 10 min | WARNING | Telegram |
| CPU | `cpu.usage > 90%` for 10 min | WARNING | Telegram |
| container died | any container status → exited | CRITICAL | Telegram |
| Postgres down | postgres connection lost | CRITICAL | Telegram |
| Redis down | redis connection lost | CRITICAL | Telegram |
| Postgres connections | `postgres.connections > 80% of max` | WARNING | Telegram |

### Alert rules (UptimeRobot — built-in)

| Alert | Trigger | Channel |
|---|---|---|
| project `/health` down | non-2xx or timeout for 5 min | Telegram + email |
| TLS expiring | cert < 14 days to expiry | email |
| TLS expired | cert expired | Telegram + email |
| Dokploy down | non-2xx on dokploy.yanoltech.com | Telegram + email |

### Alert routing (combined)

| Severity | Channel | What |
|---|---|---|
| CRITICAL | Telegram + email | app down, DB down, disk full, container died, VPS unreachable |
| WARNING | Telegram | disk > 80%, RAM > 85%, CPU > 90%, Postgres conns > 80%, TLS < 14d |
| INFO | email only | TLS expiry notice, UptimeRobot monthly uptime report |

### Telegram setup

1. Create a bot via `@BotFather` → get bot token.
2. Create a channel `@yanoltech_alerts` (or similar), add the bot as admin.
3. Put the bot token + channel chat ID into:
   - UptimeRobot alert contact (Telegram)
   - Netdata `health_alarm_notify.conf` (Telegram)
4. All alerts land in one channel. On-call watches it.

### What this layer covers

- App down (UptimeRobot external check)
- VPS unreachable (UptimeRobot external check)
- DB down / Redis down (Netdata)
- Disk full / RAM / CPU (Netdata)
- Container crashed (Netdata)
- TLS expired / expiring (UptimeRobot)
- Pipeline failures (already covered by §18c)

### What this layer does NOT cover (acceptable interim gap)

- Queryable historical metrics (no Prometheus) — you can't ask "p95 latency last week"
- Centralized log search (no Loki) — you `docker logs` per container
- Distributed tracing (no Tempo/Jaeger)
- SLOs / error budgets
- Application error tracking (no Sentry) — app logs + Netdata container health are the proxy
- Per-request latency tracking

These are tracked in §20. Add a full stack when the platform's scale justifies it. For "will I know when something is broken at 3am," this layer is sufficient.

### Deployment order (Phase 0 addition)

1. Create Telegram bot + alert channel.
2. Deploy Netdata container on VPS, wire Telegram alerts, enable the alert rules above.
3. Add UptimeRobot monitors for all 8 projects + Dokploy + PostHog (when deployed).
4. Verify: stop one project's container → confirm Netdata alerts. Block one project's `/health` → confirm UptimeRobot alerts.

Do this **before** migrating any project — so monitoring is in place when the first deploy happens.

---

## 20. Remaining Technical Debt (to track)

- GitHub org branch protection / CODEOWNERS not yet configured (tracker §2).
- **Full observability stack not yet built** (Prometheus/Grafana for queryable historical metrics, Loki for log search, Sentry for app error tracking, OpenTelemetry + Tempo/Jaeger for tracing, SLOs/error budgets). Interim layer (§19a: UptimeRobot + Netdata + Telegram) covers "is it broken" alerts; the full stack covers "what happened over time." Full stack requires VPS upgrade (§14b) or managed alternatives.
- PostHog Cloud account not yet created (§19) — sign up, create projects per Yanol product, get project keys into Infisical.
- No backup strategy implemented yet (DB + Dokploy self-backup + DR drill).
- Infisical + Bitwarden not yet set up (§12a) — Phase 0 priority.
- Plaintext credentials in `devops-implementation-tracker.md` §1 not yet migrated to Bitwarden — Phase 0 step 1.
- No secrets rotation automation yet (manual schedule via Infisical §18b; automate when error-prone).
- No staging sanitization pipeline yet (§18a).
- No pipeline-failure alerting wired yet (§18c).
- No incident response process formalized yet (§18d).
- Coder dev platform deployed 2026-09-03 on a separate server (65.86.32.81, AlmaLinux 9.8). Live at `coder.yanoltech.com`. See `coder-deployment.md`. Pending: HTTPS verification, Cloudflare SSL mode (Full strict), WebSocket verification, workspace app domains, backups, monitoring, and Yanol Tech stack templates (Go/Node/Next.js/Python).
- Duplicate `qirb-alga` project in Dokploy to clean up.
- Random `appName` suffixes in Dokploy to normalize to standard naming.
- `yanol-frontend` production currently running `:staging` image tag — must be corrected during its migration.
- Reusable workflows repo `Yanol-TEch-Solution/devops-workflows` not yet created.
- Shared infra containers not yet stood up on the server.
- IaC (OpenTofu/Terraform + Ansible) for server/DNS/Dokploy config — future.
- Preview environments per PR — future enhancement.
- Image digest pinning (`@sha256:...`) in addition to SHA tags — future hardening.
