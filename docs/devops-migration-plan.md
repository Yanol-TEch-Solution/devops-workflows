# Yanol Tech — Per-Project Migration Plan

**Last updated:** 2026-09-01
**Standard:** `devops-standard.md` · **Architecture:** `devops-architecture.md` · **Procedures:** `devops-procedures.md`

> Migration is one project at a time. Never proceed to the next project while the
> current one has an unresolved production problem.

---

## 1. Migration Order

| # | Project | Status | Notes |
|---|---|---|---|
| 1 | **oromia-president-office** (pilot) | **Done** | Production live. Validates the full pipeline. |
| 2 | yanol-website (landing page) | Pending | Already on GHCR. Fix prod=`:staging` tag bug. |
| 3 | yano-pms | Pending | Already on GHCR + has prod/staging. Add shared MySQL/Redis, health checks, SHA tags. |
| 4 | Emahus Hosting | Pending | 3 envs already, most apps (9). |
| 5 | gelan-project-management | Pending | Compose-based. First compose→standard conversion. |
| 6 | yanet-primary-hospital | Pending | Compose-based. |
| 7 | yanet-general-hospital | Pending | Compose-based. |
| 8 | medischedule-v2 | Pending | Compose-based. |
| 9 | qirb-alga | Pending | Compose-based. |

---

## 2. Pre-Migration Foundation (completed)

| Task | Status |
|---|---|
| Delete duplicate `qirb-alga` project in Dokploy | Done |
| Create `devops-workflows` repo with reusable workflows | Done (inlined due to org policy) |
| Shared infra: staging + production Postgres, MySQL, Redis | Done (6 containers) |
| GHCR registry read PAT added to Dokploy | Done |
| VPS capacity verified | Done (7.6GB RAM, 4 cores) |
| Netdata deployed on VPS | Done (alerting pending Telegram) |
| PostHog Cloud decision | Done (not self-hosting) |
| Cloudflare R2 | Skipped for now |

### Pending foundation tasks (user action)

| Task | Blocks | Status |
|---|---|---|
| Bitwarden setup | Security cleanup | Pending |
| Infisical setup | Secret management automation | Pending |
| Telegram bot | Netdata alerting | Pending |
| UptimeRobot | External monitoring | Pending |
| PostHog Cloud | Product analytics | Pending |

---

## 3. Proven Migration Process (from pilot)

This is the exact process validated on `oromia-president-office`. Follow it for each remaining project.

### Step 1: Rename branches
- `master`/`main` → `main` (set as default)
- `dev` → `development`
- Create `staging` from `development`
- Update Dokploy app branch config to `development`
- Update CI workflow triggers to `main` + `development`

```bash
gh api repos/Yanol-TEch-Solution/<project>/branches/dev/rename -X POST -f new_name="development"
gh api repos/Yanol-TEch-Solution/<project>/branches/master/rename -X POST -f new_name="main"
gh api repos/Yanol-TEch-Solution/<project> -X PATCH -f default_branch="main"
```

### Step 2: Create logical databases
- On shared staging Postgres: `<project>` DB + `<project>_user`
- On shared production Postgres: `<project>` DB + `<project>_user`
- Connection limit: 25
- Generate strong password per environment

### Step 3: Create Dokploy apps
- Staging app: `sourceType: docker`, image `ghcr.io/yanol-tech-solution/<project>:staging`
- Production app: `sourceType: docker`, image `ghcr.io/yanol-tech-solution/<project>:production`
- Set registry credentials (GHCR PAT)
- Copy env vars from existing app if migrating
- Set `DATABASE_URL` to shared Postgres connection string
- Add domains: `staging-<project>.yanoltech.com` (staging), existing domain (production)

### Step 4: Set GitHub secrets
- `DOKPLOY_API_KEY`
- `DOKPLOY_STAGING_APP_ID`
- `DOKPLOY_PRODUCTION_APP_ID`
- `DOKPLOY_DB_PROVISIONER_STAGING_ID`
- `STAGING_DB_PASSWORD`
- `PRODUCTION_DB_PASSWORD`

### Step 5: Add CD workflows
- `.github/workflows/staging.yml` — triggers on push to `staging`
- `.github/workflows/production.yml` — triggers on `workflow_dispatch` from `main`
- Use built-in `GITHUB_TOKEN` for GHCR auth (not a PAT)
- Trivy scan: exit 0 (warning) until CVEs fixed
- Health check: poll `<domain>/api/health` for HTTP 200

### Step 6: Migrate data (if existing project)
- Dump old DB: `docker exec <old-pg> pg_dump -U <user> -d <db> --no-owner --no-acl > dump.sql`
- Restore to shared: `cat dump.sql | ssh root@<vps> "docker exec -i <shared-pg> psql -U <project>_user -d <project>"`
- Verify row counts match

### Step 7: Build and deploy
- Push to `staging` → staging CD runs automatically
- Trigger `production.yml` via `workflow_dispatch` → production CD runs
- Verify both health endpoints return 200

### Step 8: Switch domains
- Remove domains from old Dokploy app
- Add domains to new Dokploy app
- Verify health, admin login, key pages, sitemap

### Step 9: Decommission old
- Stop old Dokploy app
- Stop old per-project DB container
- Delete after 24-48h monitoring

### Step 10: Create GitHub Environment
- Create `production` environment in repo settings
- Add required reviewers via GitHub UI

---

## 4. Lessons from the pilot

| Issue | Fix |
|---|---|
| Reusable workflows blocked by org policy | Inline workflows per-repo |
| GHCR push fails with PAT | Use built-in `GITHUB_TOKEN` (gets `packages:write` from `permissions:` block) |
| Trivy finds critical CVEs in base deps | Relax to exit 0, fix CVEs separately, re-enable hard gate later |
| Nested subdomains cause TLS issues | Use `staging-<project>.yanoltech.com` not `staging.<project>.yanoltech.com` |
| Next.js build fails without DATABASE_URL | Add dummy `DATABASE_URL` build arg in Dockerfile |
| postgres-js retries ECONNREFUSED with backoff | Detect dummy URL, use Proxy that throws immediately |
| Dokploy Swarm container names have suffixes | Use `docker ps \| grep <prefix>` to find exact name |
| DB provisioning needs to be automated | Use Dokploy compose helper with idempotent SQL |
| Dokploy has no container exec API | Use compose app that runs psql and exits |
