# Yanol Tech — DevOps Onboarding

One-page orientation for new engineers and admins. Read this first; the source docs hold the detail.

**Key docs:**
- `devops-procedures.md` — how work is done (deploy, rollback, monitor, onboard a project)
- `devops-standard.md` — the architecture standard all projects follow
- `devops-migration-plan.md` — per-project migration process (10 steps, proven on pilot)
- `devops-implementation-tracker.md` — current status of all work
- `devops-architecture.md` — diagrams and global server layout

---

## 1. What we're building

Standardized platform for all Yanol Tech projects:

```
Developer → GitHub → GitHub Actions → GHCR → Dokploy → Production
```

with Cloudflare in front, shared PostgreSQL/MySQL/Redis behind, and Netdata + UptimeRobot for monitoring.

| Before | Now |
|---|---|
| Manual cPanel deploys | CI/CD: Actions → GHCR → Dokploy |
| Per-project DB containers | Shared Postgres/MySQL/Redis with logical isolation |
| No rollback | Immutable SHA-tagged images, one-command rollback |
| Ad-hoc DNS/security | Centralized at Cloudflare |
| No monitoring | Netdata on VPS + UptimeRobot external checks + Telegram alerts |
| Plaintext credentials | Bitwarden (human) + Infisical (machine) |

---

## 2. Platform components

| Component | Job | Status |
|---|---|---|
| Cloudflare | DNS, TLS, WAF, CDN, DDoS, edge security | Live |
| GitHub | Source control, branch protection, PR review, Actions CI/CD | Live |
| GitHub Actions | CI: lint, test, build, scan. CD: build → GHCR → Dokploy | Live |
| GHCR | Immutable container images (`app:commit-sha`) | Live |
| Dokploy | Deploy, health checks, rollback, env config, domains, SSL | Live |
| Shared Postgres/MySQL/Redis | Per-env data layer, logical isolation per project | Live (6 containers) |
| Netdata | VPS infra/container monitoring + Telegram alerts | Live |
| UptimeRobot | External uptime + TLS cert monitoring | Live (3 monitors) |
| Telegram bot | Alert channel for Netdata + pipeline failures | Live |
| Infisical | Machine/application secrets, synced to CI | Live (2 projects) |
| Bitwarden | Human/admin credentials, shared vault, 2FA | Live (8 creds) |
| PostHog Cloud | Product analytics | Skipped for now |
| Cloudflare R2 | Off-server backups | Deferred |

---

## 3. Branch model (every project)

| Branch | Purpose | Deploy method |
|---|---|---|
| `main` | Production | CI → GHCR → Dokploy (manual `workflow_dispatch`, requires approval) |
| `staging` | Release candidate validation | CI → GHCR → Dokploy (auto on push) |
| `development` | Active development | Dokploy builds from source on server |

Short-lived branches: `feature/*`, `fix/*`, `hotfix/*` → merge to `development`.

---

## 4. Domains & DNS

Primary domain: **yanoltech.com**. Cloudflare owns DNS + edge.

**Subdomain convention:**
```
<project>.yanoltech.com              → production
staging-<project>.yanoltech.com      → staging
api-<project>.yanoltech.com          → API (if separate)
```

Never use nested subdomains like `staging.<project>.yanoltech.com` — they cause TLS issues.

**Status:** NS flipped to Cloudflare 2026-08-25, zone Active, email verified.
Cloudflare NS: `andronicus.ns.cloudflare.com`, `blakely.ns.cloudflare.com`.

---

## 5. CI/CD flow

### Staging (automatic)
```
Push to staging → GitHub Actions →
  1. Fetch secrets from Infisical
  2. Provision DB (idempotent)
  3. Build Docker image (SHA tag)
  4. Push to GHCR (:sha + :staging)
  5. Trivy scan (warning only)
  6. Update Dokploy to SHA image
  7. Deploy via Dokploy API
  8. Health check
```

### Production (manual)
```
workflow_dispatch on main → GitHub Actions →
  1. Requires reviewer approval (GitHub Environment: production)
  2. Build Docker image (SHA tag)
  3. Push to GHCR (:sha + :production)
  4. Trivy scan (hard gate — once CVEs fixed)
  5. Update Dokploy to SHA image
  6. Deploy via Dokploy API
  7. Health check
  8. Log deployment
```

### Development (automatic)
```
Push to development → Dokploy watches branch → builds on server
```

---

## 6. Secrets management

| Secret type | Storage | Sync to |
|---|---|---|
| Human/admin creds | Bitwarden `DevOps Platform` vault | Manual reference only |
| Machine/app secrets | Infisical (per-project, per-env) | GitHub Actions via Machine Identity |
| CI/CD secrets | GitHub secrets (DOKPLOY_API_KEY, app IDs) | Workflow env vars |

**Never** store credentials in: Git, Docker images, chat, email, plaintext docs.

---

## 7. Monitoring & alerting

| Layer | Tool | What it watches | Alert channel |
|---|---|---|---|
| Container/host | Netdata | CPU, RAM, disk, Docker containers | Telegram |
| External uptime | UptimeRobot | HTTP status + TLS cert expiry | Email |
| Pipeline failures | GitHub Actions | CI/CD failures | (Telegram webhook — future) |

Every project must expose `/api/health` returning `{"status":"ok","database":"up"}`.

---

## 8. Current status

| Phase | Status |
|---|---|
| Foundation (Cloudflare, Dokploy, shared infra, Netdata) | Done |
| Accounts (Bitwarden, Infisical, Telegram, UptimeRobot) | Done |
| Pilot migration (oromia-president-office) | Done — production live |
| Remaining 7 projects | Pending |
| Trivy hard gate | Relaxed (3 critical CVEs — fix then re-enable) |
| Backup automation | Deferred (R2 skipped for now) |
| PostHog analytics | Skipped for now |

**Live sites:**
- `president.yanoltech.com` — production
- `staging-president.yanoltech.com` — staging
- `api-president.yanoltech.com` — production API
- `dokploy.yanoltech.com` — Dokploy dashboard

---

## 9. Onboarding a new project

Follow `devops-procedures.md` §1 and `devops-migration-plan.md` §3. The 10-step process:

1. Rename branches (`master`→`main`, `dev`→`development`, create `staging`)
2. Create logical databases on shared Postgres
3. Create Dokploy apps (staging + production)
4. Set GitHub secrets
5. Add CD workflows (staging.yml + production.yml)
6. Migrate data (if existing project)
7. Build and deploy
8. Switch domains
9. Decommission old resources
10. Create GitHub Environment with required reviewers

No new architecture decisions needed. Same pattern, same workflows, same infra.

---

## 10. Disaster recovery

```
App down → check Cloudflare → check Dokploy → check app health
   → check logs → check DB → check infra → rollback if needed
```

Rollback = re-deploy any earlier SHA image via Dokploy API or UI.
Previous images are never deleted from GHCR.

---

## References

- `devops-procedures.md` — operational procedures (deploy, rollback, monitor, secrets, incidents)
- `devops-standard.md` — full architecture standard
- `devops-migration-plan.md` — migration process + lessons from pilot
- `devops-implementation-tracker.md` — live status
- `devops-architecture.md` — diagrams
- `dns-audit-yanoltech.com.md` — full DNS zone dump
