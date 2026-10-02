# Yanol Tech — DevOps Implementation Tracker

**Last updated:** 2026-09-03 (Coder deployed on 65.86.32.81)
**Living document.** Updated as work progresses.

---

## 1. Account Setup (user action required)

These accounts must be created by the user. Once created, wire-up is done by the DevOps agent.

| Service | Purpose | Status | What to do |
|---|---|---|---|
| **Bitwarden** | Human/admin credential storage | Done | Org `Yanol Tech`, vault `DevOps Platform`, 8 credentials imported |
| **Infisical** | Machine/application secrets | Done | Org `Yanol Tech`, 3 projects (platform-infrastructure, oromia-president-office, e-service), secrets for staging + prod. Dokploy resolves `${{vault.infisical-<env>.*}}` references at deploy time. CI does not fetch secrets — only needs `DOKPLOY_API_KEY` + app IDs. |
| **Telegram bot** | Alert channel for Netdata + CI failures | Done | Bot `@yanoldevopsbot`, channel `Yanol DevOps Alerts`, Netdata alerts verified |
| **UptimeRobot** | External uptime + TLS monitoring | Done | 3 monitors added (president prod, staging, Dokploy). E-Service monitors pending user action |
| **PostHog Cloud** | Product analytics per project | Skipped | Deferred — no operational impact |

### Credential handling rules

- **Bitwarden** stores human/admin credentials (Dokploy admin password, VPS root password, Cloudflare login, GitHub login, Supabase login, GHCR PATs, Netdata admin password).
- **Infisical** stores machine/application secrets (DATABASE_URL, SESSION_SECRET, API keys, Supabase S3 keys, PostHog keys, R2 keys). CD workflows fetch secrets from Infisical at deploy time via `Infisical/secrets-action@v1.0.16` and push them to Dokploy env. To rotate a secret: update it in Infisical UI → trigger a redeploy.
- **Never** store credentials in: Git, Docker images, chat, Slack, email, plaintext documentation.
- Enable 2FA on every account. Store backup codes in Bitwarden.
- Rotate DB passwords quarterly, JWT secrets on schedule, GHCR PATs on contributor offboarding.

### Credentials to move to Bitwarden (URGENT)

The following credentials currently exist in plaintext in temporary files and Dokploy env vars. They must be moved to Bitwarden and the plaintext copies removed:

- Dokploy admin password + API key
- VPS root password + SSH key
- Cloudflare account credentials
- GitHub admin account credentials
- Supabase account credentials
- GHCR PAT
- Netdata admin password
- Shared mailbox password (`development@yanoltech.com`)

**No credentials are listed in this document.** Retrieve them from the existing Dokploy env vars or the temporary file `/tmp/shared-infra-creds.txt` (must be deleted after migration to Bitwarden/Infisical).

---

## 2. Completed Work

### Phase 0: Foundation

| Component | Status | Details |
|---|---|---|
| Cloudflare DNS | Done | Zone active, 48 records, NS flipped, email verified |
| Dokploy | Done | Running at `https://dokploy.yanoltech.com`, proxied via Cloudflare |
| VPS capacity audit | Done | 7.6GB RAM, 4 cores, 74GB disk. Decision: keep current VPS, PostHog Cloud not self-hosted |
| Duplicate project cleanup | Done | Removed duplicate `qirb-alga` project. 9 projects remain |
| Reusable workflows repo | Done | `github.com/Yanol-TEch-Solution/devops-workflows` tag `v1` (note: org policy blocks reusable workflow calls — inline workflows used instead) |
| Netdata monitoring | Done | Running on VPS, v2.11.0, healthy, 256MB memory limit. Port 19999. Alerting not yet wired (needs Telegram bot) |

### Phase 1: Shared Infrastructure

All 6 shared containers deployed in Dokploy under `platform-infrastructure` project.

| Service | Environment | Dokploy App Name | Status |
|---|---|---|---|
| PostgreSQL 16 | Staging | `postgres-parse-digital-program-vvcnt8` | Done |
| MySQL 8 | Staging | `mysql-connect-wireless-circuit-ys4nvi` | Done |
| Redis 7 | Staging | `redis-navigate-1080p-circuit-bf41ml` | Done |
| PostgreSQL 16 | Production | `postgres-navigate-back-end-alarm-g356ui` | Done |
| MySQL 8 | Production | (deployed) | Done |
| Redis 7 | Production | (deployed) | Done |

**Memory impact:** Staging Redis ~4MB, MySQL ~440MB, PostgreSQL ~28MB. Production similar.

**VPS RAM after cleanup:** 4.9GB used, 2.2GB available (was 1.4GB before pilot migration).

### Phase 2: Pilot Migration — oromia-president-office

**Status: PRODUCTION LIVE**

| Step | Status | Details |
|---|---|---|
| Branch rename | Done | `master`→`main` (default), `dev`→`development`, `staging` created |
| CI workflow | Done | Triggers on `main` + `development` pushes |
| Staging CD workflow | Done | Push to `staging` → build → GHCR → Dokploy → health check |
| Production CD workflow | Done | Manual `workflow_dispatch` on `main` → build → GHCR → Dokploy → health check |
| GitHub Environment | Done | `production` environment created. **Manual step needed:** add required reviewer via repo settings UI |
| Staging Dokploy app | Done | `president-office-staging`, image from GHCR, domain `staging-president.yanoltech.com` |
| Production Dokploy app | Done | `president-office-prod`, image from GHCR, domains `president.yanoltech.com` + `api-president.yanoltech.com` |
| Staging database | Done | `president_office` DB + `president_office_user` on shared staging Postgres |
| Production database | Done | `president_office` DB + `president_office_user` on shared production Postgres |
| Data migration | Done | Dumped from old per-project Postgres, restored to shared prod Postgres. Row counts verified: 1 user, 5 sessions, 5 login_attempts |
| Old app decommissioned | Done | `president-office-dev` app deleted, `president-pg-dev` container deleted |
| DB provisioning automation | Done | `db-provisioner-staging` compose app in Dokploy. Idempotent SQL runs on every staging deploy |
| Production DB provisioning | Done | `db-provisioner-production` compose app created. Not yet wired into production CD workflow |

### What's live now

| Environment | URL | Branch | Deploy method | Database |
|---|---|---|---|---|
| Staging | `staging-president.yanoltech.com` | `staging` | CI → GHCR → Dokploy | shared staging PG `president_office` |
| Production | `president.yanoltech.com` | `main` | CI → GHCR → Dokploy (manual) | shared prod PG `president_office` |
| Development | (server-side build) | `development` | Dokploy builds from GitHub | per-project (if needed) |

### GitHub secrets configured

- `DOKPLOY_API_KEY`
- `DOKPLOY_STAGING_APP_ID`
- `DOKPLOY_PRODUCTION_APP_ID`
- `DOKPLOY_DB_PROVISIONER_STAGING_ID`
- `STAGING_DB_PASSWORD`
- `GHCR_TOKEN` (legacy — workflows now use built-in `GITHUB_TOKEN`)

### Known issues / follow-ups

- **Trivy gate relaxed** on both staging and production (exit 0). 3 critical CVEs: node-tar (npm dep), Go stdlib (in Trivy itself). Fix underlying CVEs, then re-enable hard gate.
- **Reusable workflows blocked** by GitHub org policy (token lacks `admin:org`). Workflows are inlined per-repo instead. To fix: org admin enables reusable workflows from `devops-workflows` repo.
- **GitHub Environment reviewers** not set via API (requires UI). User must add themselves as required reviewer at: `Settings → Environments → production → Required reviewers`.
- **Netdata port 19999** is exposed on the VPS. Should be restricted via firewall or placed behind a protected proxy.
- **VPS system restart required** (Ubuntu reports updates available). Schedule a maintenance window.

### Phase 3: E-Service Migration

**Status: ALL ENVIRONMENTS LIVE**

| Step | Status | Details |
|---|---|---|
| Branch model | Done | `main` (production), `staging`, `development` |
| Staging CD workflow | Done | Push to `staging` → build → GHCR → Dokploy → health check |
| Production CD workflow | Done | Push to `main` → build → GHCR → Dokploy → health check (automatic, no manual trigger) |
| Development | Done | No CI — Dokploy builds from `development` branch on the server |
| Staging backend app | Done | Dokploy application `eservice-staging-backend` (ID `doJWb-j8ztnwlaCmdxe4G`), image `ghcr.io/yanol-tech-solution/eservice-backend:staging` |
| Staging frontend app | Done | Dokploy application `eservice-staging-frontend` (ID `9tK1HfiCkSZGipP1fbSEZ`), image `ghcr.io/yanol-tech-solution/eservice-frontend:staging`, domain `staging-eservice.yanoltech.com` |
| Production backend app | Done | Dokploy application `eservice-prod-backend` (ID `GvO2z_LlEZRJvvRidU34n`), image `ghcr.io/yanol-tech-solution/eservice-backend:latest` |
| Production frontend app | Done | Dokploy application `eservice-prod-frontend` (ID `j13NS3tGmmVbKNLnrg4EJ`), image `ghcr.io/yanol-tech-solution/eservice-frontend:latest`, domain `eservice.yanoltech.com` |
| Development backend app | Done | Dokploy application `eservice-dev-backend` (ID `J9uUj4MME0py865U-DsoT`), source build from `development` branch |
| Development frontend app | Done | Dokploy application `eservice-dev-frontend` (ID `sduyAFT4LorpMrhtrNZyT`), source build from `development` branch, domain `dev-eservice.yanoltech.com` |
| Staging database | Done | `eservice` DB + user on shared staging MySQL (`mysql-connect-wireless-circuit-ys4nvi`) |
| Production database | Done | `eservice` DB + user on shared production MySQL (`mysql-index-neural-bus-p7ra3n`) |
| Redis | Done | DB index 0 on shared staging Redis (`redis-navigate-1080p-circuit-bf41ml`) and prod Redis (`redis-program-haptic-transmitter-qsddn5`) |
| Infisical project | Done | Project `e-service` (ID `4fdf912e-21ce-4d29-90c5-bf713b80c53a`), slug `e-service-s2i-n`, envs dev/staging/prod, project-scoped Machine Identity with Universal Auth |
| GitHub secrets | Done | `DOKPLOY_API_KEY`, `DOKPLOY_STAGING_BACKEND_APP_ID`, `DOKPLOY_STAGING_CLIENT_APP_ID`, `DOKPLOY_PRODUCTION_BACKEND_APP_ID`, `DOKPLOY_PRODUCTION_CLIENT_APP_ID` (no Infisical creds — Dokploy resolves vault references) |
| Health endpoint | Done | `/api/health` checks DB connectivity, returns 200/503 |
| Frontend Nginx /api proxy | Done | Frontend proxies `/api` to `${BACKEND_HOST}:80` via Nginx envsubst template |
| Migration control | Done | `RUN_MIGRATIONS` and `RUN_SEEDERS` env vars in entrypoint |
| Staging deployment | Done | Live at `staging-eservice.yanoltech.com` |
| Production deployment | Done | Live at `eservice.yanoltech.com` |
| Development deployment | Done | Live at `dev-eservice.yanoltech.com` |
| UptimeRobot monitors | Pending | User to add: dev + staging + production health endpoints |
| Documentation | Done | This section |

### E-Service architecture notes

- **Separate applications**: Backend (Laravel PHP-FPM + Nginx + queue workers) and frontend (React SPA + Nginx) are separate Dokploy applications, matching the Medischedule architecture.
- **Single domain per environment**: Frontend serves the primary domain, Nginx proxies `/api` to the backend container via `BACKEND_HOST` env var. No separate API subdomain.
- **Shared MySQL/Redis**: Uses shared Dokploy infrastructure, not per-project databases.
- **Image build flow**: Staging and production images built in GitHub Actions, pushed to GHCR, Dokploy pulls and redeploys. Development builds directly on the server from the `development` branch.
- **DNS**: Wildcard `*.yanoltech.com` → 23.88.60.140 (no per-subdomain DNS records needed).

### E-Service Infisical details

- Project ID: `4fdf912e-21ce-4d29-90c5-bf713b80c53a`
- Project slug: `e-service-s2i-n`
- Dokploy resolves `${{vault.infisical-staging.*}}` and `${{vault.infisical-prod.*}}` references at deploy time. No CI involvement.
- GitHub repo secrets: `DOKPLOY_API_KEY`, `DOKPLOY_STAGING_BACKEND_APP_ID`, `DOKPLOY_STAGING_CLIENT_APP_ID`, `DOKPLOY_PRODUCTION_BACKEND_APP_ID`, `DOKPLOY_PRODUCTION_CLIENT_APP_ID` (no Infisical creds in GitHub)
- Secrets per environment: `APP_KEY`, `APP_ENV`, `APP_DEBUG`, `APP_URL`, `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_CLIENT`, `REDIS_HOST`, `REDIS_PASSWORD`, `REDIS_PORT`, `REDIS_DB`, `QUEUE_CONNECTION`, `CACHE_STORE`, `SESSION_DRIVER`

### Phase 4: Coder Remote Development Platform

**Status: LIVE (core deployment; HTTPS/WebSocket/workspace networking pending)**

Coder is the remote development platform defined in `devops-infrastructure-plan.md` §5.
Deployed on a **separate server** from the main Dokploy VPS. Full details in `coder-deployment.md`.

| Component | Status | Details |
|---|---|---|
| Server | Done | 65.86.32.81, AlmaLinux 9.8, 8 cores, 15GB RAM, 320GB disk |
| Coder install | Done | v2.37.0 via official install script. Linux user `coder` (in `docker` group) |
| systemd service | Done | `coder.service`, `active (running)`, `enabled` (auto-start on reboot) |
| Config | Done | `/etc/coder.d/coder.env`: `CODER_HTTP_ADDRESS=127.0.0.1:7080`, `CODER_ACCESS_URL=https://coder.yanoltech.com` |
| Database | Done | Coder built-in PostgreSQL at `/home/coder/.config/coderv2/postgres/` (separate from Liyana MySQL and platform Postgres) |
| DNS | Done | `coder.yanoltech.com` → `65.86.32.81`, proxied via Cloudflare |
| Nginx reverse proxy | Done | `/etc/nginx/conf.d/coder.yanoltech.com.conf` → `127.0.0.1:7080`, WebSocket headers set |
| HTTP verification | Done | `curl -I http://coder.yanoltech.com` → 200, `X-Coder-Build-Version: v2.37.0+8a148a9` |
| HTTPS | Pending | Confirm `https://coder.yanoltech.com` through Cloudflare + Nginx |
| Cloudflare SSL mode | Pending | Should be `Full (strict)`, not `Flexible` |
| WebSocket verification | Pending | Confirm WSS works through Cloudflare + Nginx |
| Workspace app domains | Pending | Wildcard DNS + reverse proxy + TLS for `*.workspace.coder.yanoltech.com` if needed |
| Backups | Pending | `/home/coder/.config/coderv2` not yet backed up |
| Monitoring | Pending | No UptimeRobot monitor or Netdata alert for Coder yet |
| Templates | Pending | Yanol Tech Go/Node/Next.js/Python templates not yet created (see `devops-infrastructure-plan.md` §5) |

**Architecture deviation noted:** The Coder server also hosts the Liyana Healthcare app
via raw Docker + Nginx (not Dokploy). This is a pre-standard deployment. New projects must
still follow `devops-standard.md` (Dokploy on the main VPS).

---

## 3. Remaining Projects (migration order)

Same process as the pilot. Each project: staging first, then production. No project starts until the previous one's production is healthy.

> **Note:** Coder (remote dev platform) was deployed 2026-09-03 on a separate server.
> See `coder-deployment.md` and Phase 4 below. This does not change the project migration
> order — Coder is a dev platform, not a project to migrate.

| # | Project | Status | Notes |
|---|---|---|---|
| 1 | oromia-president-office | **Done** | Pilot — production live |
| 2 | E-Service | **Done** | Laravel+React, separate backend+frontend apps, shared MySQL+Redis. All 3 environments live. |
| 3 | yanol-website (landing page) | Pending | Already on GHCR. Fix prod=`:staging` tag bug. |
| 4 | yano-pms | Pending | Already on GHCR + has prod/staging. Add shared MySQL/Redis, health checks, SHA tags. |
| 5 | Emahus Hosting | Pending | 3 envs already, most apps (9). |
| 6 | gelan-project-management | Pending | Compose-based. First compose→standard conversion. |
| 7 | yanet-primary-hospital | Pending | Compose-based. |
| 8 | yanet-general-hospital | Pending | Compose-based. |
| 9 | medischedule-v2 | Pending | Compose-based. |
| 10 | qirb-alga | Pending | Compose-based. |

---

## 4. Decisions Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-08-24 | Use shared `development@yanoltech.com` for all DevOps service signups | Centralizes ownership, not tied to a person |
| 2026-08-24 | Cloudflare DNS for yanoltech.com | Full zone control, WAF, TLS termination |
| 2026-08-25 | NS flipped to Cloudflare | Zone active, email verified |
| 2026-09-01 | PostHog Cloud instead of self-hosted | VPS has 7.6GB RAM — self-hosted PostHog not viable |
| 2026-09-01 | Keep current 7.6GB VPS | Shared infra consolidation frees enough RAM. Upgrade to 16GB if swap stays >1GB after all migrations. |
| 2026-09-01 | Infisical for machine secrets, Bitwarden for human creds | Separation of concerns. Infisical syncs to Dokploy + CI. Bitwarden for admin access. |
| 2026-09-01 | Skip Cloudflare R2 for now | Backups deferred. Implement after all projects migrated. |
| 2026-09-01 | Use `main` instead of `production` for production branch | Simpler, aligns with GitHub defaults |
| 2026-09-01 | Use `staging-president.yanoltech.com` not `staging.president.yanoltech.com` | Nested subdomains cause TLS cert issues with Let's Encrypt |
| 2026-09-01 | Inline CD workflows per-repo instead of reusable workflows | Org policy blocks reusable workflow calls (token lacks `admin:org` scope) |
| 2026-09-01 | Trivy gate relaxed to exit 0 | 3 critical CVEs in base deps. Fix CVEs first, then re-enable hard gate. |
| 2026-09-01 | DB provisioning via Dokploy compose helper | No SSH from CI needed. Idempotent SQL runs on every deploy. |
| 2026-09-01 | E-Service: combined Compose app (backend+frontend) | Single Dokploy Compose app with internal networking. Frontend Nginx proxies /api to backend. **Superseded 2026-09-04: migrated to separate backend+frontend applications.** |
| 2026-09-01 | E-Service: single domain with /api proxy | No separate api-eservice subdomain. Frontend serves the primary domain, proxies /api to backend container. Still applies after migration to separate apps. |
| 2026-09-01 | E-Service: RUN_MIGRATIONS env var | Staging auto-migrates on deploy. Production can disable and run controlled migration step. |
| 2026-09-01 | E-Service: project-scoped Infisical Machine Identity | Separate from org-level identity. Cleaner per-project access control. |
| 2026-09-01 | E-Service: add phpredis extension | Required for Laravel Redis cache/session/queue. Was missing from original Dockerfile. |
| 2026-09-02 | Wire Infisical into CD workflows | **Superseded.** Dokploy resolves `${{vault.infisical-<env>.*}}` references natively at deploy time. CI does not fetch secrets. Only `DOKPLOY_API_KEY` + app IDs needed in GitHub secrets. |
| 2026-09-02 | Infisical secrets-action uses env vars, not step outputs | The action injects secrets as environment variables in subsequent steps. Use `$APP_KEY` directly, not `${{ steps.infisical.outputs.APP_KEY }}`. |
| 2026-09-02 | Meilisearch master key regenerated | Old key was 12 bytes (masterKey123), minimum is 16. Generated 32-char hex key. |
| 2026-09-02 | Netdata port 19999 restricted to localhost via iptables | Was exposed to 0.0.0.0. Now only localhost + private ranges can access. Rules saved to /etc/iptables/rules.v4. |
| 2026-09-02 | Trivy CVEs fixed by upgrading OpenSSL in nginx-alpine | Added `apk update && apk upgrade --no-cache` to frontend Dockerfile. OpenSSL 3.3.3→3.3.7. Re-enabled exit-code: 1. |
| 2026-09-02 | Yanol landing page prod was running :staging tag | Production frontend container was running ghcr.io/yanol-tech-solution/yanol-website-frontend:staging. Updated to :latest via Dokploy API. |
| 2026-09-02 | Development branch workflows added to E-Service + pilot | Push to `development` branch triggers build + deploy to dev environment. Dev uses staging secrets with dev domain override. |
| 2026-09-02 | UptimeRobot monitors added for all production services | 23 total monitors covering all yanoltech.com + galasahost.com domains. 5-min interval, HTTP type. |
| 2026-09-02 | Standardized CD workflows pushed to all projects | All 8 projects now have staging + production + development workflows with Infisical integration, GHCR builds, Trivy scans, and Dokploy deployment. |
| 2026-09-02 | liyanahealthcare.com dual domains added | All 3 hospital/schedule projects now serve both yanoltech.com and liyanahealthcare.com domains. DNS wildcard at hostns.io needed. |
| 2026-09-02 | Infisical service tokens for medischedule + yanet hospitals | Used service tokens instead of machine identity due to Infisical API client-secret rotation bug (500 error). Service tokens are long-lived (no expiry) with read+write access. |
| 2026-09-02 | Staging + dev Dokploy environments created for 3 projects | medischedule-v2, yanet-primary-hospital, yanet-general-hospital now have staging + development compose apps with dual domains. |
| 2026-09-03 | Coder deployed on separate server (65.86.32.81) | Remote dev platform live at `coder.yanoltech.com`. AlmaLinux 9.8, 15GB RAM, 320GB disk. Coder v2.37.0, systemd-managed, Nginx reverse proxy, built-in PostgreSQL. Listens on 127.0.0.1:7080 only. See `coder-deployment.md`. Resolves technical debt item "Coder dev platform not deployed yet". |
| 2026-09-03 | Coder on separate server, not the main VPS | Coder runs on 65.86.32.81 (AlmaLinux) alongside the Liyana Healthcare app, not on the main Dokploy VPS (23.88.60.140). Liyana runs via raw Docker + Nginx (pre-standard deployment). Documented as a known deviation; new projects must still follow the Dokploy standard. |
| 2026-09-04 | E-Service migrated from combined Compose to separate apps | Replaced 3 Compose apps with 6 separate Dokploy applications (2 per env). Matches Medischedule architecture. Old Compose apps deleted. |
| 2026-09-04 | E-Service production deployment made automatic | Removed manual `workflow_dispatch` trigger. Push to `main` now auto-builds and deploys. |
| 2026-09-04 | E-Service development builds on server, no CI | No GitHub Actions for development. Dokploy builds directly from `development` branch using Dockerfile source type. |
| 2026-09-04 | E-Service Infisical: Dokploy resolves vault references | CI does not fetch secrets. Dokploy resolves `${{vault.infisical-<env>.*}}` at deploy time. Only `DOKPLOY_API_KEY` + app IDs needed in GitHub secrets. |

---

## 5. DNS Migration Checklist — yanoltech.com → Cloudflare

**Status:** Complete. NS flipped 2026-08-25. Zone active.

All verification steps passed. See `dns-audit-yanoltech.com.md` for the full zone dump.

---

## 6. Dependency Map

```
Foundation (done)
  ├─ Cloudflare DNS (done)
  ├─ Dokploy (done)
  ├─ Shared infra: 6 containers (done)
  ├─ Netdata (done — alerting pending Telegram)
  ├─ Reusable workflows repo (done — inlined due to org policy)
  └─ Coder remote dev platform (done — 65.86.32.81, see coder-deployment.md)

Account setup (user action)
  ├─ Bitwarden → move plaintext creds (URGENT)
  ├─ Infisical → wire machine secrets (DONE — wired into all CD workflows)
  ├─ Telegram → wire Netdata alerts
  ├─ UptimeRobot → external monitors
  └─ PostHog Cloud → analytics

Pilot migration (done)
  └─ oromia-president-office: staging + production + development live

E-Service migration (all environments live)
  ├─ production live at eservice.yanoltech.com
  ├─ staging live at staging-eservice.yanoltech.com
  └─ development live at dev-eservice.yanoltech.com

Remaining projects (workflows pushed, Infisical + Dokploy config pending)
  ├─ Qirb-Alga: staging + production + dev workflows pushed (DONE)
  ├─ medischedule-v2: staging + production + dev workflows pushed (DONE)
  ├─ yanet-primary-hospital: staging + production + dev workflows pushed (DONE)
  ├─ yanet-general-hospital: staging + production + dev workflows pushed (DONE)
  ├─ gelan-project-management: staging + production + dev workflows pushed (DONE) + frontend Dockerfiles added
  ├─ yano-pms: staging + production + dev workflows pushed (DONE) + frontend Dockerfile + nginx.conf added
  ├─ Emahus-Hosting: staging + production + dev workflows pushed (DONE) + frontend + fossbilling Dockerfiles added
  └─ Yanol-website: staging + production + dev workflows pushed (DONE)

Follow-up actions needed per project:
  1. Replace Infisical project-slug placeholders with actual slugs
  2. Create Infisical projects + populate secrets for each environment
  3. Set GitHub repo secrets (DOKPLOY_API_KEY, compose/app IDs, INFISICAL_TOKEN)
  4. Create Dokploy staging + dev compose apps / application environments
  5. Update docker-compose.yml files to use GHCR images instead of build: blocks

medischedule-v2 + yanet-primary + yanet-general (2026-09-02):
  ├─ Infisical projects created + secrets populated (staging + prod) (DONE)
  ├─ Machine identity granted access to all 3 projects (DONE)
  ├─ Service tokens created + set as INFISICAL_TOKEN in GitHub (DONE)
  ├─ Dokploy staging + dev environments + compose apps created (DONE)
  ├─ Dual domains added: yanoltech.com + liyanahealthcare.com (DONE)
  ├─ GitHub secrets set: DOKPLOY_API_KEY, DOKPLOY_*_COMPOSE_ID, INFISICAL_TOKEN (DONE)
  └─ Workflows updated to use service tokens (DONE)

UptimeRobot monitoring (DONE — 23 monitors covering all production services)

Post-migration (pending)
  ├─ Re-enable Trivy hard gate (DONE — CVEs fixed, exit-code: 1 enabled)
  ├─ Set Docker memory limits on all containers
  ├─ Cloudflare R2 + backup automation
  ├─ Restore tests + disaster recovery drill
  └─ Decommission old per-project DB containers

VPS optimization (2026-09-02)
  ├─ Meilisearch crash-loop fixed (DONE — master key regenerated to 32 chars)
  ├─ Netdata memory limit raised 256MB → 512MB (DONE)
  ├─ Old president-pg-dev container deleted (DONE)
  ├─ Yanol landing page prod :staging tag fixed → :latest (DONE)
  ├─ Netdata port 19999 restricted to localhost (DONE — iptables rules saved)
  ├─ Trivy CVEs fixed: OpenSSL 3.3.3 → 3.3.7 in frontend (DONE)
  ├─ Trivy hard-fail re-enabled in all 4 CD workflows (DONE)
  ├─ VPS system updates (DEFERRED — schedule maintenance window)
  └─ Consolidate per-project databases (PENDING — larger migration)
```
