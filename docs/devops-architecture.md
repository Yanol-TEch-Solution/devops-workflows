# Yanol Tech — Global Architecture & Diagrams

**Last updated:** 2026-09-03
**Standard:** `devops-standard.md` · **Procedures:** `devops-procedures.md` · **Migration:** `devops-migration-plan.md`
**Server:** single VPS hosting ~8 projects via Dokploy (23.88.60.140).
**Dev platform:** Coder on a separate server (65.86.32.81) — see `coder-deployment.md`.
**Edge:** Cloudflare (DNS, WAF, TLS, DDoS) → Traefik (Dokploy built-in) → containers.

---

## 1. Global Server Architecture

```text
                              INTERNET
                                 │
                                 ▼
                          ┌──────────────┐
                          │  Cloudflare  │
                          │ DNS·WAF·TLS  │
                          └──────┬───────┘
                                 │
                                 ▼
                ┌────────────────────────────────┐
                │   Single VPS (23.88.60.140)    │
                │   7.6GB RAM · 4 cores · 74GB   │
                │   ┌──────────────────────────┐ │
                │   │  Traefik (reverse proxy) │ │
                │   └───────────┬──────────────┘ │
                │               │                │
                │   ┌───────────┴──────────────┐ │
                │   │  Per-project app containers│ │
                │   │  (Next.js, Go, etc.)       │ │
                │   └───────────┬──────────────┘ │
                │               │                │
                │   ┌───────────┴──────────────┐ │
                │   │   Shared infra (per env) │ │
                │   │  ┌────────┐ ┌──────┐     │ │
                │   │  │Postgres│ │MySQL │     │ │
                │   │  └────────┘ └──────┘     │ │
                │   │  ┌────────┐ ┌──────┐     │ │
                │   │  │ Redis  │ │Netdata│    │ │
                │   │  └────────┘ └──────┘     │ │
                │   └──────────────────────────┘ │
                └────────────────────────────────┘
```

### Networks (Docker)

| Network | Members | Purpose |
|---|---|---|
| `dokploy-network` | all apps + shared infra | default Dokploy network |
| per-project dev net | dev app + dev infra (compose) | dev self-contained |

No public ports on any DB/Redis. Only Traefik exposes app HTTP(S).

---

## 1a. Coder Server (Remote Development Platform)

Coder runs on a **separate server** from the main Dokploy VPS. It is the remote development
platform defined in `devops-infrastructure-plan.md` §5 — for development only, not CI/CD
or production deployment. Full details in `coder-deployment.md`.

```text
                              INTERNET
                                 │
                                 ▼
                       coder.yanoltech.com
                                 │
                                 ▼
                          Cloudflare
                                 │
                              HTTPS
                                 │
                                 ▼
                   Server: 65.86.32.81 (AlmaLinux 9.8)
                   8 cores · 15GB RAM · 320GB disk
                                 │
                                 ▼
                            Nginx :80/:443
                                 │
                          reverse proxy
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
        127.0.0.1:7080     127.0.0.1:3000     127.0.0.1:5000
           Coder          Liyana Frontend     Liyana Backend
              │                  │                  │
              ▼                  └────────┬─────────┘
     Built-in PostgreSQL          ▼
                            MySQL (liyana_db)
```

| Field | Value |
|---|---|
| Server IP | `65.86.32.81` |
| OS | AlmaLinux 9.8 |
| Coder version | v2.37.0 |
| Coder internal address | `127.0.0.1:7080` (not publicly exposed) |
| Coder domain | `coder.yanoltech.com` |
| Coder data | `/home/coder/.config/coderv2` (built-in PostgreSQL) |
| Coder service | `coder.service` (systemd, enabled) |
| Reverse proxy | Nginx (`/etc/nginx/conf.d/coder.yanoltech.com.conf`) |

> **Note:** This server also hosts the Liyana Healthcare app via raw Docker + Nginx
> (not Dokploy). That is a pre-standard deployment, not the pattern for new projects.
> New projects follow `devops-standard.md` (Dokploy on the main VPS 23.88.60.140).

---

## 2. Development Flow

```text
Developer
   │
   ▼
GitHub  development branch
   │
   ▼
Dokploy watches development branch  →  builds on server (model B)
   │
   ▼
Development deployment
   ├── App container(s)
   └── Per-project infra (if needed)
```

- No GHCR involved in dev. No commit-SHA image for dev.
- Server-side build only for development.

---

## 3. Staging Flow

```text
GitHub  staging branch  (push)
   │
   ▼
GitHub Actions  (staging.yml)
   ├── docker build  →  ghcr.io/yanol-tech-solution/<project>:<sha>
   ├── docker push   →  also tag :staging alias
   ├── Trivy scan (warning only — exit 0)
   └── call Dokploy API  (update image → deploy → poll status)
   │
   ▼
Dokploy pulls image from GHCR  (model A, no server build)
   │
   ▼
Dokploy resolves ${{vault.infisical-staging.*}} references  →  injects secrets into container env
   │
   ▼
Staging deployment
   ├── Shared staging Postgres  (project's logical DB + user)
   ├── Shared staging MySQL     (project's logical DB + user, if needed)
   └── Shared staging Redis     (project's DB index, if needed)
   │
   ▼
Health check  →  https://staging-<project>.yanoltech.com/api/health
   healthy = done   |   unhealthy = pipeline fails
```

---

## 4. Production Flow

```text
GitHub  main branch  (manual workflow_dispatch)
   │
   ▼
GitHub Actions  (production.yml, environment: production)
   ├── Requires reviewer approval (GitHub Environment)
   ├── docker build  →  ghcr.io/yanol-tech-solution/<project>:<sha>
   ├── docker push   →  also tag :production alias
   ├── Trivy scan (hard gate — once CVEs fixed, currently exit 0)
   └── call Dokploy API  (update image → deploy → poll status)
   │
   ▼
Dokploy pulls image from GHCR  (model A)
   │
   ▼
Dokploy resolves ${{vault.infisical-prod.*}} references  →  injects secrets into container env
   │
   ▼
Production deployment
   ├── Shared production Postgres  (project's logical DB + user)
   ├── Shared production MySQL     (project's logical DB + user, if needed)
   └── Shared production Redis     (project's DB index, if needed)
   │
   ▼
Health check  →  https://<project>.yanoltech.com/api/health
   │
   ▼
Deployment logged in GitHub Actions summary
```

---

## 5. Shared Infrastructure (live)

### Containers deployed in Dokploy

| Service | Environment | Dokploy App Name | Status |
|---|---|---|---|
| PostgreSQL 16 | Staging | `postgres-parse-digital-program-vvcnt8` | Live |
| MySQL 8 | Staging | `mysql-connect-wireless-circuit-ys4nvi` | Live |
| Redis 7 | Staging | `redis-navigate-1080p-circuit-bf41ml` | Live |
| PostgreSQL 16 | Production | `postgres-navigate-back-end-alarm-g356ui` | Live |
| MySQL 8 | Production | (deployed) | Live |
| Redis 7 | Production | (deployed) | Live |
| Netdata | VPS | `netdata` | Live (256MB limit) |

### Logical database isolation

```text
PRODUCTION                              STAGING
────────────                            ────────
postgres-navigate-back-end-alarm-g356ui  postgres-parse-digital-program-vvcnt8
  ├── president_office (user+db)          ├── president_office (user+db)
  ├── <next_project>    (user+db)         ├── <next_project>    (user+db)
  └── ...                                └── ...

MySQL + Redis: same pattern, logical DBs / DB indexes per project
```

### Isolation guarantees

- Project A credentials → cannot auth to Project B's database
- Staging credentials → cannot auth to production infra
- Each project gets its own DB user with `CONNECTION LIMIT 25`
- App containers join `dokploy-network` and reach DBs by container name

### VPS resource budget

| Resource | Total | Used | Available |
|---|---|---|---|
| RAM | 7.6GB | ~4.9GB | ~2.2GB |
| CPU | 4 cores | — | — |
| Disk | 74GB | ~52% | ~35GB |
| Swap | 4GB | high usage | monitor |

**Upgrade to 16GB if:** swap stays >1GB after all migrations, or available RAM drops below 1GB.

---

## 6. Secrets & Access Management

```text
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  Bitwarden   │     │  Infisical   │     │    GitHub    │
│              │     │              │     │   Secrets    │
│ Human/admin  │     │ Machine/app  │     │              │
│ credentials  │     │ secrets      │     │ DOKPLOY_API  │
│              │     │              │     │ _KEY         │
│ - Dokploy    │     │ - DB_HOST    │     │ DOKPLOY_*    │
│ - VPS root   │     │ - DB_PASSWORD│     │  _APP_ID     │
│ - Cloudflare │     │ - JWT_SECRET │     │              │
│ - GitHub     │     │ - REDIS_HOST │     │ (no Infisical│
│ - Supabase   │     │              │     │  creds needed│
│ - GHCR PAT   │     │  per project │     │  in CI)      │
│ - Netdata    │     │  per env     │     │              │
└──────────────┘     └──────┬───────┘     └──────────────┘
                            │
                   Dokploy native integration
                   (${{vault.infisical-<env>.*}} references)
                            │
                            ▼
                   At deploy time, Dokploy:
                   1. Pulls image from GHCR
                   2. Resolves ${{vault...}} refs via Infisical API
                   3. Injects real secret values into container env
                   4. Starts container
```

CI never touches app secrets. CI only builds images and calls Dokploy deploy API.

### Infisical project structure

```text
Organization: Yanol Tech
├── platform-infrastructure
│   ├── dev
│   ├── staging    (STAGING_POSTGRES_ADMIN_PASSWORD, etc.)
│   └── prod       (PRODUCTION_POSTGRES_ADMIN_PASSWORD, etc.)
└── oromia-president-office
    ├── dev
    ├── staging    (DATABASE_URL, STAGING_DB_PASSWORD)
    └── prod       (DATABASE_URL, PRODUCTION_DB_PASSWORD)
```

Machine Identity `github-actions` has Universal Auth access to both projects, all environments.

---

## 7. Monitoring & Alerting

```text
┌─────────────────────────────────────────────────┐
│  VPS                                             │
│  ┌──────────┐    ┌──────────────────────────┐   │
│  │ Netdata  │───▶│ Telegram channel         │   │
│  │ (port    │    │ "Yanol DevOps Alerts"    │   │
│  │  19999)  │    │ via @yanoldevopsbot      │   │
│  └──────────┘    └──────────────────────────┘   │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  External (UptimeRobot)                         │
│  ┌────────────┐    ┌──────────────────────┐     │
│  │ Monitors   │───▶│ Email alerts         │     │
│  │            │    │                      │     │
│  │ - pres.yt  │    │  HTTP keyword: "ok"  │     │
│  │ - stg-pres │    │  TLS cert expiry     │     │
│  │ - dokploy  │    │                      │     │
│  └────────────┘    └──────────────────────┘     │
└─────────────────────────────────────────────────┘
```

| Layer | Tool | What it monitors | Alert channel | Status |
|---|---|---|---|---|
| Container/host | Netdata | CPU, RAM, disk, Docker, per-container | Telegram | Live |
| External uptime | UptimeRobot | HTTP status + TLS cert expiry | Email | Live (3 monitors) |
| Pipeline | GitHub Actions | CI/CD failures | (Telegram — future) | Partial |

---

## 8. Traceability Chain (every production deploy)

```text
Git commit  →  GitHub Actions run  →  Docker image  →  GHCR tag :<sha>  →
Trivy scan  →  Dokploy deploy  →  health check  →  running container
```

Rollback = re-deploy any earlier `<sha>` via Dokploy API or UI. Previous images never deleted from GHCR.

---

## 9. Component Responsibility Map

| Component | Responsibility | Status |
|---|---|---|
| Cloudflare | DNS, TLS, WAF, DDoS, edge security | Live |
| Traefik (Dokploy) | reverse proxy, routing, TLS termination at server | Live |
| Coder | remote development workspaces (separate server 65.86.32.81) | Live (core; HTTPS/WS pending) |
| Nginx (Coder server) | reverse proxy for Coder + Liyana on 65.86.32.81 | Live |
| GitHub | source control, branch protection, PR review | Live |
| GitHub Actions | CI (lint/test/build/scan) + CD (build/push/deploy) | Live |
| GHCR | immutable image storage (`:<sha>`) | Live |
| Dokploy | deployment, health checks, rollback, env vars, domains | Live |
| Shared Postgres/MySQL/Redis | per-env data layer, logical isolation per project | Live |
| Netdata | infra/container/DB health monitoring on VPS | Live |
| UptimeRobot | external uptime + TLS monitoring | Live |
| Telegram bot | alert channel for Netdata + pipeline failures | Live |
| Infisical | machine/application secrets, resolved by Dokploy at deploy time | Live |
| Bitwarden | human/admin credentials, shared vault, 2FA | Live |
| PostHog Cloud | product analytics | Skipped |
| Cloudflare R2 | off-server DB + Dokploy backups | Deferred |

---

## 10. Adding a 9th Project

Follow `devops-procedures.md` §1 and `devops-migration-plan.md` §3. No new architecture decisions required.

```text
1. Rename branches (master→main, dev→development, create staging)
2. Create logical DB + user on shared Postgres (staging + prod)
3. Create Dokploy apps (staging + production, GHCR-backed)
4. Set GitHub secrets (DOKPLOY_API_KEY, app IDs only — no Infisical creds needed)
5. Add CD workflows (staging.yml + production.yml)
6. Migrate data (if existing project)
7. Build and deploy (staging auto, production manual)
8. Switch domains
9. Decommission old resources
10. Create GitHub Environment with required reviewers
```

Same pattern, same workflows, same infra.
