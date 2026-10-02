# Yanol Infrastructure — Master Documentation

**Last updated:** 2026-09-28 · **Maintainer notes start here.** This is the entry
point. Everything else links from here.

## Document map

| File | What it is | Git |
|---|---|---|
| `README.md` (this file) | Architecture, standards, current state, history | ✅ tracked |
| `RUNBOOK.md` | Operational procedures: onboarding, deploy/rollback, triage, gotchas | ✅ tracked |
| `AGENTS.md` | Rules for AI agents working on this infra | ✅ tracked |
| `toolkit/` | Scripts: provision-db, new-project, new-app, deploy, backup-verify (+ `state/` IDs) | ✅ tracked (state/ ignored) |
| `credentials.template.md` | Placeholder template | ✅ tracked |
| `credentials.md` | **ALL secrets + IDs — LOCAL ONLY, gitignored** | ❌ never |
| `backup/` | Data-rescue dumps (client PII) — local only | ❌ never |
| `infisical-compose.yml` | Self-hosted Infisical compose **with ENCRYPTION_KEY** — local only | ❌ never |

## Infrastructure at a glance

**Production VPS — 65.86.32.81** (`server.galasahost.com`, 8 cores / 16GB / 320GB):
- Docker Swarm + **Dokploy** (dashboard https://dokploy.yanoltech.com — public, plus
  SSH tunnel `:3002`) with its own Postgres
- **Traefik v3.6** owns 80/443 (nginx stopped+disabled, old containers stopped = rollback)
- **Shared MySQL 8.0** (`mysql-hack-neural-application-mhksas`) — no public port,
  one `<project>_prod` database + `<project>_user` per project
- **Self-hosted Infisical** — https://infisical.yanoltech.com (PRIMARY secrets store,
  compose: app + Postgres + Redis, pinned v0.165.16)
- **rclone** configured (remote `r2` → Cloudflare R2)

**Old VPS — 23.88.60.140** (`liyanahealthcare` host, runs the old dokploy.yanoltech.com):
reference/archive only. Old apps scaled to 0 (tpms ×6, house-registration ×2, yanet,
gelan, old-emahus ×3, visit-bishoftu, old-qirb). Do not delete without fresh backups.

## Current production (all verified 2026-09-28)

| Project (Dokploy) | Apps | Domain(s) | DB on shared MySQL | Infisical project | Backups (02:00/02:30 UTC → R2) |
|---|---|---|---|---|---|
| `liyana` | backend / web / admin | liyanahealthcare.com, www, api., admin. | `liyana_prod` / `liyana_user` | `liyana` (folders /backend /web /admin) | `shared-mysql-backups` → liyana_prod |
| `emahus` | backend / frontend / billing | emahushosting.com, api., billing. | `emahus_prod` + `billing_prod` (own users) | `emahushosting` (folders /backend /frontend /billing) | `emahus-backups`, `billing-backups` |
| `yanol-website` | frontend / backend | yanoltech.com, www | `yanol-website_prod` / `yanol-website_user` | `yanol-website` (folders /backend /frontend) | `yanol-backups` (uploads bind /opt/yanol-website/uploads) |
| `yanet` | compose: db / backend / frontend | **yanetprimaryhospital.com** (LIVE final, + www; temp .yanoltech.com detached) | dedicated mariadb:11.4 inside its stack (`yanet_db`) | `yanet` (folder /app in prod) | `yanet-backups` (02:50, host cron /opt/yanet-backup/backup.py) |
| `oro-fresh` | application: Next.js 15 (oro-fresh-web) | **oro-fresh.yanoltech.com** | `oro_prod` / `oro_user` | `oro-fresh` (folder /app in prod, 19 secrets) | `oro-backups` (02:00) |
| `sidama-pdo` | compose: app (Laravel) / frontend (SPA) | **sidama-pdo.yanoltech.com** | `sidama_prod` / `sidama_user` | `sidama-pdo` (folder /app in prod, 24 secrets) | `sidama-backups` (02:10) |
| `medischedule` | compose: backend / frontend (ghcr images, raw) | **medischedule.yanoltech.com** (cut over from 23.88) | `medischedule_prod` / `medischedule_user` (data migrated) | secrets recorded in compose env | `medischedule-backups` (02:20) |
| `pharma-link` | compose: backend (Laravel) / frontend (SPA) | **pharma-link.yanoltech.com** | `pharma_prod` / `pharma_user` | secrets in compose env (recorded in credentials) | add pharma-backups job when data lands |
| `pharmalink-marketplace` | application: Next.js storefront (marketplace-web) | **pharmalink-marketplace.yanoltech.com** | none — uses pharma_prod via Laravel /api/marketplace | secrets in app env (recorded in credentials) | n/a (no DB) |
| `yano-pms` | compose: pms-app (Laravel, multi-tenant) / frontend (SPA) | **pms.yanoltech.com** | `pms_prod` + dynamic `tenant<uuid>` DBs / `pms_user` | secrets in compose env (recorded in credentials) | add pms-backups job when data lands |
| `md-hms` | compose: postgres + hms-backend (Laravel, multi-tenant PG) + 2 SPA dashboards | **hms.yanoltech.com** + hms-admin.yanoltech.com | dedicated postgres (hms_central + tenant DBs) | secrets in compose env (recorded in credentials) | add backup job when real data lands |
| `qirb-alga` | compose: postgis + Laravel fpm/api + Next web + 2 SPA dashboards (branch feat/review-feedback) | **qirb-alga.yanoltech.com** + qirb-admin. + qirb-dashboard. | dedicated postgis (`qirb_central`) | secrets in compose env (recorded in credentials) | add backup job when data lands |
| `infrastructure` | shared-mysql, infisical compose | infisical.yanoltech.com | — | — | `infisical-backups` (02:30, host cron) |

Mail for `emahushosting.com`: cPanel mailbox `no-reply@` on fra2.hostclusters.com
(SMTP 465); backend sends via Infisical-injected SMTP settings. SMS still `log`
(AfroMessage credentials pending). Email for `yanoltech.com` exists separately
(info@ on its own cPanel).

## The standards (how we do everything)

1. **Deployment** — Dokploy pulls source (GitHub App `ogjLjeKl769Aj0y3v5o0D`, org
   `Yanol-TEch-Solution`) and builds on the server using optimized Dockerfiles
   (BuildKit npm cache, Next standalone, non-root). No CI/CD; redeploys via
   toolkit/dashboard. Swarm `failureAction=rollback` auto-reverts bad deploys.
2. **Secrets** — one **Infisical project per product** (self-hosted now; free-tier
   cloud = 3 projects max, legacy `medischedule-v2` is archive). Folders per app
   (`/backend`, `/web`, …). Apps reference `${{vault.<providerName>.<KEY>}}`;
   one Dokploy vault provider per app, internal URL `http://infisical:8080`.
3. **Databases** — shared MySQL instance; `CREATE DATABASE x_prod` + scoped
   `x_user` per project (toolkit: `provision-db.sh`). No public ports, ever.
4. **Backups** — nightly 02:00 UTC (Dokploy jobs) + 02:30 UTC Infisical (host cron
   `/opt/infisical-backup/backup.py`) → Cloudflare R2 `abeselom-backup`, one prefix
   per source. Restore drills are mandatory after setup (liyana ✓, infisical ✓).
5. **Local stack** — every project repo carries `docker-compose.yml` + `.env.example`
   + `Makefile` + `docs/DEPLOYMENT.md` (Liyana is the reference implementation).
6. **Secrets hygiene** — never in git, never in images (`.dockerignore` excludes
   `.env*`), never baked at build (except declared `VITE_*`/`NEXT_PUBLIC_*` ARGS).

## Domain/DNS notes

- All domains on Cloudflare. App domains point A → 65.86.32.81 (proxied).
- **Mail hostnames must be DNS-only** (Cloudflare does not proxy SMTP).
- `mail.emahushosting.com` → 84.16.253.0 (fra2 cPanel); MX → itself.
- `*.yanoltech.com` legacy wildcard previously pointed at 23.88 — now individual
  records; `dokploy.` and `infisical.` point here.

## Timeline (2026-09-26 → 09-28)

- **09-26/27 — Liyana migration:** data + env rescued from old stack → Dockerfiles
  optimized (standalone/cache mounts) → local stack verified → Dokploy #2 installed
  on 65.86.32.81 → shared MySQL + Infisical integration → GitHub App → all three
  apps built-from-source and cut over (Traefik replaced nginx; old stack paused).
- **09-27 — Infisical debugging:** "env not applying" root-caused twice — swarm
  rollback masking a bad credential pair, then later an f-string brace bug. Both
  documented as gotchas; rotation proven end-to-end.
- **09-28 — Emahus migration + Infisical self-host:** DBs rescued locally (client
  data!) → emahus project (backend/frontend/billing) deployed fresh/empty on
  shared MySQL → domains live → SMTP wired (cPanel mailbox) → **Infisical
  self-hosted** (compose + infisical.yanoltech.com) → 88 secrets migrated → vault
  providers re-pointed to internal URL → all apps verified → Infisical DB backup
  pipeline + restore drill.
- **Tooling:** dev-ops git repo (local only), toolkit scripts, RUNBOOK, AGENTS.

## Leftovers / TODO

- [ ] FOSSBilling: finish installer (billing.emahushosting.com), set its SMTP to
      the no-reply mailbox; decide admin passwords + store in Infisical.
- [ ] Traefik ACME email: replace `test@localhost.com` in
      `/etc/dokploy/traefik/traefik.yml` with a real address.
- [ ] After 1–2 stable weeks: drop `liyana_dev` + old `liyana` user on shared
      MySQL; retire stopped old containers (keep volume `backend_db_data` until
      confident; it holds the pre-migration liyana DB).
- [ ] AfroMessage credentials for SMS (`SMS_TRANSPORT=afromessage`) — same wiring
      as SMTP.
- [ ] Delete `/liyana` + `/emahus` folders from cloud Infisical (UI only — API 500s),
      then optionally delete the `medischedule-v2` cloud project entirely (frees a
      free-tier project slot).
- [ ] Mailcow (self-hosted mail on this VPS) — port 25 open, PTR exists, ~6GB RAM;
      would make the VPS's current MX pointing correct. Own session.
- [ ] Rename cloud Infisical project `medischedule-v2` if kept.
- [ ] First git commit of dev-ops (local repo ready, deliberately zero commits so
      far — operator decides when).

## Toolkit quick reference

```bash
cd dev-ops/toolkit
./provision-db.sh <project>              # DB + user on shared MySQL
./new-project.sh <name>                  # Dokploy project + Infisical project + state
./new-app.sh <project> <app> <repo> <build-path> [--secrets-file f] [--port N]
./deploy.sh <project> <app> --watch      # deploy + detect crash/rollback
./backup-verify.sh                       # read-only backup check
DRY_RUN=1 ./provision-db.sh test         # preview without executing
```
