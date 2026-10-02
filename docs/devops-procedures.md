# Yanol Tech — DevOps Operational Procedures

**Last updated:** 2026-09-01
**Purpose:** How work is done from now on. This is the proven, repeatable process validated on the pilot project.

> If a 9th project is added tomorrow, follow this document. No new architecture decisions needed.

---

## 1. How to onboard a new project

### 1.1 Prerequisites (already done — verify once)

- [x] Dokploy running at `https://dokploy.yanoltech.com`
- [x] Shared infra: staging + production Postgres, MySQL, Redis
- [x] Cloudflare DNS for `yanoltech.com` active
- [x] GitHub org `Yanol-TEch-Solution` with GHCR enabled
- [x] Netdata monitoring on VPS

### 1.2 Steps (per project)

**Step 1 — Branches:**
- Rename `master`/`main` → `main` (production, default branch)
- Rename `dev` → `development`
- Create `staging` from `development`
- Update Dokploy app branch config to `development`
- Update CI workflow triggers to `main` + `development`

**Step 2 — GitHub secrets:**
- `DOKPLOY_API_KEY` — Dokploy API key
- `DOKPLOY_STAGING_APP_ID` — staging app ID (after creating in step 4)
- `DOKPLOY_PRODUCTION_APP_ID` — production app ID (after creating in step 4)
- `DOKPLOY_DB_PROVISIONER_STAGING_ID` — DB provisioner compose ID
- `DOKPLOY_DB_PROVISIONER_PRODUCTION_ID` — DB provisioner compose ID
- `STAGING_DB_PASSWORD` — generated strong password
- `PRODUCTION_DB_PASSWORD` — generated strong password

**Step 3 — Databases:**
- Create logical DB + user on shared staging Postgres
- Create logical DB + user on shared production Postgres
- Use the DB provisioner compose apps in Dokploy (idempotent SQL)
- Or run directly via SSH: `docker exec <pg-container> psql -U yanol_admin -d postgres -c "CREATE DATABASE <project>; CREATE USER <project>_user WITH ENCRYPTED PASSWORD '<pass>' CONNECTION LIMIT 25; GRANT ALL PRIVILEGES ON DATABASE <project> TO <project>_user; ALTER DATABASE <project> OWNER TO <project>_user;"`

**Step 4 — Dokploy apps:**
- Create staging app: `sourceType: docker`, image `ghcr.io/yanol-tech-solution/<project>:staging`, registry `ghcr.io`, port 3000
- Create production app: same but image `:production`
- Add domains: `staging-<project>.yanoltech.com` (staging), `<project>.yanoltech.com` (production)
- **Domain naming:** use `staging-<project>.yanoltech.com` (single-level subdomain), NOT `staging.<project>.yanoltech.com` (nested — causes TLS issues)
- Copy env vars from existing app if migrating, or set new ones
- Set `DATABASE_URL` to `postgres://<project>_user:<pass>@<pg-container>:5432/<project>`

**Step 5 — CD workflows:**
- Add `.github/workflows/staging.yml` (triggers on push to `staging`)
- Add `.github/workflows/production.yml` (triggers on `workflow_dispatch` from `main`)
- Use built-in `GITHUB_TOKEN` for GHCR auth (not a PAT)
- Trivy scan: exit 0 for staging (warning), exit 1 for production (hard gate) — once CVEs are fixed
- Health check: poll `<domain>/api/health` for HTTP 200

**Step 6 — GitHub Environment:**
- Create `production` environment in repo settings
- Add required reviewers (manual via GitHub UI)

**Step 7 — Data migration (if migrating existing project):**
- Dump old DB: `docker exec <old-pg> pg_dump -U <user> -d <db> --no-owner --no-acl > dump.sql`
- Restore to shared: `cat dump.sql | ssh root@<vps> "docker exec -i <shared-pg> psql -U <project>_user -d <project>"`
- Verify row counts match

**Step 8 — Domain switch:**
- Remove domains from old Dokploy app
- Add domains to new Dokploy app
- Verify health endpoint returns 200
- Verify admin login, key pages, sitemap

**Step 9 — Decommission old:**
- Stop old Dokploy app
- Stop old per-project DB container
- Delete both after 24-48h monitoring

### 1.3 Post-migration checklist

- [ ] Staging health check passes
- [ ] Production health check passes
- [ ] Admin login works
- [ ] Key pages load
- [ ] Sitemap accessible
- [ ] Old app stopped
- [ ] Old DB container removed
- [ ] VPS RAM improved
- [ ] UptimeRobot monitor added (after account created)

---

## 2. How to deploy

### 2.1 Staging deploy

**Automatic:** push to `staging` branch.

```
git checkout staging
git pull
git push origin staging
```

The CD workflow:
1. Provisions DB (idempotent)
2. Builds Docker image with commit SHA tag
3. Pushes to GHCR (`:sha` + `:staging` alias)
4. Trivy scan (warning only)
5. Updates Dokploy app to SHA image
6. Triggers Dokploy deploy
7. Polls Dokploy until status is `done`
8. Polls `https://staging-<project>.yanoltech.com/api/health` for HTTP 200

**Time:** ~5-6 minutes.

### 2.2 Production deploy

**Manual:** trigger via GitHub Actions UI or `gh` CLI.

```
gh workflow run production.yml --repo Yanol-TEch-Solution/<project> --ref main
```

The CD workflow:
1. Requires manual approval (GitHub Environment `production` with required reviewers)
2. Builds Docker image with commit SHA tag
3. Pushes to GHCR (`:sha` + `:production` alias)
4. Trivy scan (hard gate — once CVEs fixed)
5. Updates Dokploy app to SHA image
6. Triggers Dokploy deploy
7. Polls Dokploy until status is `done`
8. Polls `https://<project>.yanoltech.com/api/health` for HTTP 200
9. Records deployment in GitHub summary

**Time:** ~6-7 minutes (including approval wait).

### 2.3 Development deploy

**Automatic:** Dokploy watches the `development` branch and builds from source on push.

No GHCR image. Server-side build only.

---

## 3. How to roll back

### 3.1 Dokploy rollback (quick)

1. Go to Dokploy → application → settings
2. Change `dockerImage` to the previous SHA tag
3. Click Deploy
4. Verify health endpoint

Or via API:
```bash
curl -X POST "https://dokploy.yanoltech.com/api/application.update" \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"applicationId":"<app-id>","dockerImage":"ghcr.io/yanol-tech-solution/<project>:<previous-sha>"}'

curl -X POST "https://dokploy.yanoltech.com/api/application.deploy" \
  -H "x-api-key: $DOKPLOY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"applicationId":"<app-id>"}'
```

### 3.2 Database rollback

- Every forward migration must have a rollback migration
- Run rollback migration manually before rolling back the app image
- Keep the previous app image running until rollback is verified

### 3.3 Full rollback (emergency)

1. Roll back DB (run down migration)
2. Roll back app image (Dokploy → previous SHA)
3. Verify health
4. If shared infra is the problem, restore from latest DB dump

---

## 4. How to provision a database

### Automated (preferred)

The CD workflow does this automatically on every staging deploy via the `db-provisioner-staging` compose app in Dokploy.

For manual provisioning or new projects:

```bash
# Via SSH to VPS
docker exec <pg-container> psql -U yanol_admin -d postgres -c "CREATE DATABASE <project>;"
docker exec <pg-container> psql -U yanol_admin -d postgres -c "CREATE USER <project>_user WITH ENCRYPTED PASSWORD '<pass>' CONNECTION LIMIT 25;"
docker exec <pg-container> psql -U yanol_admin -d postgres -c "GRANT ALL PRIVILEGES ON DATABASE <project> TO <project>_user;"
docker exec <pg-container> psql -U yanol_admin -d postgres -c "ALTER DATABASE <project> OWNER TO <project>_user;"
```

### Container names

| Service | Staging container | Production container |
|---|---|---|
| PostgreSQL | `postgres-parse-digital-program-vvcnt8` | `postgres-navigate-back-end-alarm-g356ui` |
| MySQL | `mysql-connect-wireless-circuit-ys4nvi` | (check Dokploy) |
| Redis | `redis-navigate-1080p-circuit-bf41ml` | (check Dokploy) |

Note: Docker Swarm appends replica suffixes (`.1.<random>`). Use `docker ps --format '{{.Names}}' | grep <prefix>` to find the exact name.

---

## 5. How to monitor

### Current monitoring (interim)

| Layer | Tool | What it monitors | Status |
|---|---|---|---|
| Container/host | Netdata | CPU, RAM, disk, Docker containers, per-container metrics | Running, alerting not wired |
| External uptime | UptimeRobot | HTTP status + TLS cert expiry for all project health endpoints | Pending account creation |
| Alerts | Telegram | Netdata alerts + CI/CD failure notifications | Pending bot creation |
| Product analytics | PostHog Cloud | Events, sessions, funnels, feature flags | Pending account creation |

### Health endpoints

Every project must expose `/api/health` returning:
- HTTP 200 `{"status":"ok","database":"up"}` when healthy
- HTTP 503 `{"status":"degraded","database":"down"}` when DB is unreachable

### What to check manually

```bash
# VPS health
ssh root@23.88.60.140 "free -h && df -h && docker stats --no-stream"

# App health
curl -s https://<project>.yanoltech.com/api/health

# Dokploy app status
curl -s -H "x-api-key: $DOKPLOY_API_KEY" "https://dokploy.yanoltech.com/api/application.one?applicationId=<id>" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('applicationStatus'))"

# Container status
ssh root@23.88.60.140 "docker ps --format '{{.Names}}\t{{.Status}}' | grep <project>"
```

---

## 6. How to manage secrets

### Current state (transitional)

- Dokploy env vars store application secrets (DATABASE_URL, SESSION_SECRET, etc.)
- GitHub secrets store CI/CD secrets (DOKPLOY_API_KEY, app IDs, DB passwords)
- Plaintext credentials exist in temporary files — must be moved to Bitwarden

### Target state (after account setup)

| Secret type | Storage | Sync to |
|---|---|---|
| Human/admin creds | Bitwarden `DevOps Platform` vault | Manual reference only |
| Machine/app secrets | Infisical (per-project, per-env) | Dokploy env vars + GitHub Actions |
| CI/CD secrets | Infisical → GitHub secrets | Auto-synced via Infisical GitHub Action |

### Secret naming convention

- `DATABASE_URL` — full connection string
- `SESSION_SECRET` — random 32+ char string
- `<SERVICE>_API_KEY` — service-specific API keys
- `SUPABASE_S3_*` — Supabase storage credentials
- `POSTHOG_KEY` — PostHog project key
- `DOKPLOY_*` — Dokploy API credentials (CI only)

---

## 7. How to back up

### Current state

No automated backups yet. R2 deferred.

### Target state

| What | Frequency | Target | Retention |
|---|---|---|---|
| PostgreSQL dumps | Daily | Cloudflare R2 `yanol-backups` | Daily ×7, weekly ×4, monthly ×6 |
| MySQL dumps | Daily | Cloudflare R2 `yanol-backups` | Daily ×7, weekly ×4, monthly ×6 |
| Dokploy config | Daily | Cloudflare R2 `yanol-backups` | Daily ×7, weekly ×4, monthly ×6 |
| Restore test | Monthly | Temporary container | Verify row counts + app starts |
| Disaster recovery drill | Annual | Full restore to new VPS | Verify all projects come up |

---

## 8. VPS access

- SSH alias: `local-ssh-connect` (connects to `root@23.88.60.140`)
- Dokploy URL: `https://dokploy.yanoltech.com`
- Dokploy API: `https://dokploy.yanoltech.com/api/<endpoint>` with `x-api-key` header
- Netdata: `http://23.88.60.140:19999` (port should be restricted)

### VPS resource limits

- RAM: 7.6GB total, 2.2GB available after pilot migration
- CPU: 4 cores
- Disk: 74GB, ~52% used
- Swap: 4GB (high usage — monitor after each migration)
- **Upgrade to 16GB if:** swap stays >1GB after all migrations, a project needs dedicated infra, full observability is required, or a 9th project reduces headroom below 1GB

### Docker memory limits (mandatory)

All containers must have memory limits set. Shared infra limits:
- PostgreSQL: 512MB
- MySQL: 512MB
- Redis: 128MB
- Netdata: 256MB (reservation 128MB)
- App containers: 512MB default, adjust per project

---

## 9. Incident response

### Severity levels

| Level | Definition | Response time | Action |
|---|---|---|---|
| P0 | Production site down | Immediate | Roll back to last known good image, check DB, check Docker |
| P1 | Production degraded | 30 min | Check health endpoint, logs, DB connections |
| P2 | Staging down | 4 hours | Check CI/CD, rebuild, redeploy |
| P3 | Non-critical issue | Next business day | Investigate, fix in development branch |

### P0 runbook

1. Check if the app container is running: `ssh root@23.88.60.140 "docker ps | grep <project>"`
2. Check health: `curl -s https://<project>.yanoltech.com/api/health`
3. Check logs: `ssh root@23.88.60.140 "docker logs <container> --tail 50"`
4. If app crash: roll back to previous image via Dokploy API
5. If DB down: check shared Postgres container, restart if needed
6. If VPS overloaded: check `free -h`, `docker stats`, kill non-essential containers
7. Notify via Telegram channel (once wired)

---

## 10. Domain naming convention

| Environment | Pattern | Example |
|---|---|---|
| Production | `<project>.yanoltech.com` | `president.yanoltech.com` |
| Staging | `staging-<project>.yanoltech.com` | `staging-president.yanoltech.com` |
| API (if separate) | `api-<project>.yanoltech.com` | `api-president.yanoltech.com` |

**Never use nested subdomains** like `staging.president.yanoltech.com` — they cause Let's Encrypt TLS certificate issuance issues.

All domains use Cloudflare proxy (orange cloud) with Let's Encrypt certificates managed by Dokploy/Traefik.
