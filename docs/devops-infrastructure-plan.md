# Yanol Tech — DevOps & Engineering Infrastructure Plan

> **⚠️ SUPERSEDED** — This was the original planning document. The current architecture,
> procedures, and status are documented in:
> - `devops-standard.md` — the approved standard
> - `devops-procedures.md` — how work is done
> - `devops-architecture.md` — diagrams and live infrastructure
> - `devops-implementation-tracker.md` — current status
> - `devops-migration-plan.md` — proven migration process
>
> This document is kept for historical reference only. Do not use it for current decisions.

**Status:** Superseded (2026-09-01)
**Original status:** Proposal → Implementation
**Owner:** DevOps
**Scope:** Migration from GitHub + cPanel to a standardized DevOps platform
**Source:** Adapted from `~/Downloads/Yanol-Tech-DevOps-Infrastructure-Plan(2).md`

> Implementation progress is tracked in `devops-implementation-tracker.md`.
> Credentials live in the tracker's Section 1 — keep this plan doc free of secrets.

---

## Executive Summary

Yanol Tech currently ships software through a manual, tightly-coupled pipeline: developers push to GitHub, and deployment happens through cPanel. This works at small scale, but creates risk as the number of applications and developers grows — production and development are not separated, rollbacks are unreliable, and infrastructure knowledge lives in individual people rather than in documented, reproducible systems.

This plan proposes a standardized platform built on **Cloudflare, Coder, GitHub Actions, GHCR, and Dokploy**, with dedicated database, backup, and monitoring layers. The migration is incremental — cPanel is not removed on day one, and each application moves only after its dependencies are understood.

| Today | Target |
|---|---|
| Manual cPanel deploys | Automated CI/CD through GitHub Actions → GHCR → Dokploy |
| Dev environments = personal laptops | Standardized remote workspaces via Coder |
| No clear rollback path | Automatic, health-check-based rollback |
| DNS/security ad hoc | Centralized at Cloudflare |
| Backups inconsistent | Automated, tested, off-server backups |
| Little to no observability | Prometheus, Grafana, Sentry, centralized logs, PostHog |

---

## Table of Contents

1. Current State & Limitations
2. Target Architecture
3. Platform Components & Responsibilities
4. Domains & DNS
5. Development Environments — Coder
6. Source Control — GitHub
7. CI/CD Pipeline
8. Container Registry — GHCR
9. Deployment — Dokploy
10. Rollback Strategy
11. Environments (Preview / Staging / Production)
12. Database Architecture & Backups
13. File & Object Storage
14. Observability
15. Alerting
16. Security
17. Secrets Management
18. Infrastructure as Code
19. Onboarding & Offboarding
20. Disaster Recovery
21. Documentation & Runbooks
22. Standard for New Applications
23. Migration Roadmap
24. Appendix: References

---

## 1. Current State & Limitations

```text
Developer → GitHub → cPanel → Application → Database (on cPanel)
```

This model is simple but doesn't scale. Specific limitations:

- No clear separation between production and development infrastructure
- Deployments depend on manual cPanel configuration
- Developer environments are controlled by individual machines; source code can live permanently on laptops
- Rollbacks are uncontrolled
- Database infrastructure is coupled to hosting
- Monitoring and alerting are minimal
- Infrastructure knowledge depends on individual administrators
- Adding a new application/domain is manual work
- Disaster recovery gets harder as infrastructure grows

**Migration principle:** incremental and low-risk. cPanel is not removed until every dependency has a proven replacement.

---

## 2. Target Architecture

```text
                              INTERNET
                                 │
                                 ▼
                          ┌──────────────┐
                          │  Cloudflare  │
                          │ DNS·WAF·TLS  │
                          └──────┬───────┘
                                 │
                ┌────────────────┴────────────────┐
                ▼                                  ▼
           DEVELOPMENT                        PRODUCTION
                │                                  │
                ▼                                  ▼
             CODER                             DOKPLOY
                │                                  │
        ┌───────┴───────┐                  ┌───────┼───────┐
        ▼               ▼                  ▼       ▼       ▼
    Workspace       Workspace              Web     API   Worker
        │               │
        └───────┬───────┘
                ▼
             GitHub
                │
                ▼
         GitHub Actions
                │
        ┌───────┴───────┐
        ▼               ▼
      Test            Build
        └───────┬───────┘
                ▼
              GHCR
                │
                ▼
            Dokploy → Production
```

**Supporting infrastructure:**

```text
Production                          Observability
  ├── Managed PostgreSQL              ├── Prometheus
  ├── Redis (where required)          ├── Grafana
  ├── Object Storage                  ├── Centralized Logs
  ├── Automated Backups               ├── Sentry
  └── Monitoring                      └── Telegram / Email Alerts

Product Analytics
  └── PostHog
```

---

## 3. Platform Components & Responsibilities

Each component has exactly one job. This is the core discipline that keeps the platform maintainable as it grows.

| Component | Responsibility |
|---|---|
| **Cloudflare** | DNS, TLS, WAF, CDN, DDoS/edge security |
| **Coder** | Remote development environments only — *not* CI/CD or deployment |
| **GitHub** | Source control, branch protection, PR review |
| **GitHub Actions** | CI: lint, test, build, scan |
| **GHCR** | Immutable container image storage |
| **Dokploy** | Application deployment, health checks, rollback |
| **Managed PostgreSQL** | Critical persistent data |
| **Object Storage (S3-compatible)** | Application files (images, docs, invoices, backups) |
| **Prometheus / Grafana** | Infrastructure metrics & dashboards |
| **Sentry** | Application-level error tracking |
| **PostHog** | Product analytics (not infrastructure) |
| **Centralized Logs** | Application/infrastructure event history |

---

## 4. Domains & DNS

Primary domain: **yanoltech.com**

```text
Registrar → Cloudflare (DNS, TLS, WAF, CDN, security rules) → Applications
```

The registrar keeps domain registration/ownership; Cloudflare owns DNS and edge security. Cloudflare's WAF supports managed and custom rules for filtering unwanted web/API traffic.

**Standard subdomain convention:**

```text
yanoltech.com / www.yanoltech.com

app.yanoltech.com          staging.yanoltech.com
api.yanoltech.com          api-staging.yanoltech.com
admin.yanoltech.com        preview-123.yanoltech.com
```

Exact subdomains are defined per application, but every application must follow this pattern rather than inventing its own.

**Implementation status:** Cloudflare account created (see tracker §1). Next: add yanoltech.com zone, migrate registrar NS, configure WAF rules.

---

## 5. Development Environments — Coder

Coder becomes Yanol Tech's internal remote development platform — for **development only**. It is explicitly not a CI/CD or production deployment tool.

```text
Coder
  ├── Developer A Workspace
  ├── Developer B Workspace
  └── Developer C Workspace
         │
         ▼
      GitHub
```

Workspaces are defined by Terraform-based templates and are accessible via VS Code, JetBrains, Vim, SSH, or browser.

### Core principle: source code never lives on the laptop

The whole point of Coder, for Yanol Tech, is that the **laptop is a thin client** — not a place where code is stored. The workflow must be:

```text
Developer's Laptop                    Coder Workspace (remote)
────────────────────                  ─────────────────────────
Remote IDE / browser / SSH  ────────► git clone happens HERE
No local checkout                     Code lives HERE
No local .git folder                  Builds/tests run HERE
No local secrets/.env                 Secrets injected HERE
```

In practice this means:

- Developers connect to their Coder workspace through a remote IDE session (VS Code Remote, JetBrains Gateway, browser IDE, or SSH into the workspace) — they never run `git clone` on their own machine.
- The only thing installed locally is the thin client (editor + Coder CLI). No language runtime, no dependencies, no `.env` files, no copy of the repository.
- File sync/local checkout extensions must be disabled or blocked by policy — the workspace is the single source of truth, not a mirror.
- When a developer leaves, revoking their Coder and GitHub access is sufficient to cut off all code access, because **there is no local copy to also worry about**. This closes the biggest gap in the current model, where source code can persist on a personal laptop indefinitely after offboarding.

**Why it matters:**
- Standardized environments — no more "works on my machine"
- Company source code physically never leaves company-controlled infrastructure
- Offboarding becomes a single, complete action instead of "revoke access and hope nothing was copied"
- Fast, consistent onboarding/offboarding
- Enforced resource limits and approved templates

**Standard templates by stack:**

```text
Yanol Tech Go Template
Yanol Tech Node Template
Yanol Tech Next.js Template
Yanol Tech Python Template
```

A template defines OS, CPU/RAM/disk, Docker, git, language runtime, CLI tools, IDE integration, env vars, and dev services — so a developer never manually installs Go, Node, Docker, Postgres, or Redis per project. Templates support persistent and ephemeral resources to control cost and lifecycle.

> **Deployment status (2026-09-03):** Coder is live at `coder.yanoltech.com` on a separate
> server (65.86.32.81, AlmaLinux 9.8). Core installation, systemd service, Nginx reverse
> proxy, and domain routing are working. Pending: HTTPS verification, Cloudflare SSL mode
> (Full strict), WebSocket verification, workspace app domains, backups, monitoring, and
> the Yanol Tech stack templates listed above. See `coder-deployment.md` for full details.

---

## 6. Source Control — GitHub

```text
Developer (thin client) → Coder Workspace (clone + branch happen here) →
Pull Request → GitHub Actions → Review → Merge
```

The developer's laptop only ever sends keystrokes/commands to the workspace — it never holds a checkout of the repository.

**Required repository settings:**
- Protected production branches
- Required CI checks before merge
- Mandatory PR review
- Dependabot (or equivalent) for dependency updates
- Secret scanning
- CODEOWNERS where appropriate
- Least-privilege permissions
- Deployment credentials kept separate from developer credentials

---

## 7. CI/CD Pipeline

GitHub Actions is the CI system for every repository.

```text
Pull Request
   → Lint
   → Unit Tests
   → Integration Tests
   → Security Checks
   → Docker Build
   → Container Scan
   → Merge
   → Build Production Image
   → Push to GHCR
   → Deploy via Dokploy
```

**Hard rule:** CI fails the pipeline if tests or required security checks fail. Production deployment never depends on a developer manually building on their own machine.

---

## 8. Container Registry — GHCR

All production images are stored in GHCR with **immutable** tags:

```text
ghcr.io/yanol-tech/application:commit-sha
ghcr.io/yanol-tech/application:v1.5.0
```

This creates a direct, auditable chain:

```text
Git commit → Docker image → Production deployment
```

...and makes rollback safe and predictable.

---

## 9. Deployment — Dokploy

Dokploy is the primary deployment platform for all applications.

```text
GitHub → GitHub Actions → Docker Build → GHCR → Dokploy → Production
```

Dokploy manages: deployments, containers, environment configuration, domains, SSL, deployment history, health checks, restarts, and rollbacks — including registry-based rollback tied to specific GHCR images.

---

## 10. Rollback Strategy

Every application must expose a health endpoint (e.g. `/health`).

```text
Deploy new version → Start new version → Health check
                                              │
                                    ┌─────────┴─────────┐
                                  Healthy?            Unhealthy?
                                    │                    │
                                 Continue             Auto Rollback
```

Dokploy supports automatic rollback on failed health checks and registry-based rollback to a previous image. This behavior is mandatory in the standard application template — not optional per project.

---

## 11. Environments (Preview / Staging / Production)

```text
Development → Preview → Staging → Production
```

**Preview environments** (per pull request):

```text
PR #142 → GitHub Actions → Build image → Deploy → preview-142.yanoltech.com
```

Preview environments must **never** use production databases. Use one of: an ephemeral database, a dedicated dev database, or a sanitized snapshot.

**Isolation rule:** every environment has its own environment variables, secrets, databases, API credentials, and (where possible) external integrations. Production credentials are never available inside development environments.

---

## 12. Database Architecture & Backups

### Architecture

Databases are decoupled from application hosting.

```text
Application → Managed PostgreSQL
                 ├── Automated Backups
                 ├── Point-in-Time Recovery
                 ├── Monitoring
                 └── Replication (where required)
```

Managed databases are preferred for critical production workloads. Smaller applications can stay self-hosted, but the database must never be tightly coupled to the deployment server itself.

### Backup policy (minimum, all databases)

```text
Automated daily backup + Retention policy + Off-server storage + Restore testing
```

### Critical systems (additional requirements)

```text
Point-in-time recovery + Replication + Defined RPO + Defined RTO
```

**Rule:** a backup that has never been restored is not considered a reliable backup. Restore tests must be scheduled, not assumed.

---

## 13. File & Object Storage

Applications should not depend on local VPS disk for important user files (images, documents, invoices, attachments, generated files, backups).

```text
Application → Object Storage (S3-compatible) → Backup / Replication
```

This decouples file durability from any single server, making migration and server replacement far easier.

---

## 14. Observability

| Layer | Tool | Answers |
|---|---|---|
| Infrastructure metrics | Prometheus | Is the infrastructure healthy? |
| Dashboards/alerting | Grafana | What does it look like over time? |
| Logs | Centralized logging | What exactly happened? |
| Application errors | Sentry | What is breaking inside the app? |
| Product usage | PostHog | How are users behaving? |

### Infrastructure monitoring
CPU, RAM, disk usage & I/O, network traffic, container health, VPS availability, database health/connections, Redis health, backup status.

### Application monitoring
HTTP 5xx errors, request latency & volume, exceptions, queue/worker failures, health check status.

### Sentry
Each deployment should be tagged with a release/version so errors trace back to a specific deployment.

### PostHog
Used strictly for product analytics — usage, journeys, funnels, feature adoption, retention, experiments — never infrastructure monitoring. Keep this boundary clean:

```text
PostHog     → user/product behavior
Sentry      → application errors
Prometheus  → infrastructure metrics
Logs        → detailed events
```

---

## 15. Alerting

Alerts are centralized and delivered via Telegram and email, using a severity model:

| Severity | Meaning |
|---|---|
| **CRITICAL** | Immediate response required |
| **WARNING** | Investigate soon |
| **INFO** | Operational notice only |

**Critical alert triggers:** deployment failed, application unhealthy, automatic rollback occurred, server unavailable, disk nearly full, database unavailable, backup failed, high error rate, high CPU/RAM, SSL certificate issue, suspicious traffic.

**Rule:** don't route every application event to Telegram — alert fatigue destroys the signal.

---

## 16. Security

### Server hardening
- SSH key authentication only; disable password SSH login
- Firewall with minimal exposed ports
- Automatic security updates
- Non-root administrative access
- Restricted management interfaces

### Cloudflare
DNS, TLS, WAF (managed + custom rules), DDoS protection, rate limiting, edge security.

### GitHub
Branch protection, mandatory PR review, secret scanning, dependency scanning, least-privilege tokens, environment-specific deployment credentials.

---

## 17. Secrets Management

Secrets are **never** committed to GitHub: `DATABASE_URL`, `JWT_SECRET`, `API_KEYS`, `STRIPE_SECRET`, `SMTP_PASSWORD`, etc.

- Development, staging, and production use **separate** secrets — no sharing across environments
- Environment-level secrets in Dokploy are acceptable initially
- A dedicated secrets manager (e.g. Vault, Infisical) should be introduced as the platform grows

> **Note:** The shared mailbox and Cloudflare credentials currently live in the tracker doc (§1). These must be moved into the secrets manager once it is stood up, and removed from plaintext docs.

---

## 18. Infrastructure as Code

```text
OpenTofu / Terraform + Ansible + GitHub Actions
```

Should eventually cover: servers, networks, firewall rules, DNS config, databases, object storage, Coder infrastructure, monitoring, and deployment config.

**Goal:** a new administrator can understand and reproduce the infrastructure without relying on undocumented manual configuration.

---

## 19. Onboarding & Offboarding

### Onboarding
```text
Create employee account → GitHub access → Coder access →
Select project template → Workspace auto-created →
Clone repo → Start working
```
No manual install of Go, Node, Docker, Postgres, Redis, or project tooling — the Coder template provides it.

### Offboarding
```text
Disable Coder account → Revoke GitHub access → Revoke deployment access →
Revoke SSH access → Revoke credentials/tokens → Archive/delete workspace per policy
```

Because developers never hold a local checkout (see Section 5), this sequence is a **complete** cutoff of code access — not just a best effort. There's no separate step of "hope they didn't keep a clone on their laptop."

---

## 20. Disaster Recovery

Every critical system needs defined recovery objectives:

- **RPO** (Recovery Point Objective) — how much data can we afford to lose?
- **RTO** (Recovery Time Objective) — how fast must the system recover?

**Example:**
```text
Critical application → RPO: 1 hour · RTO: 4 hours
```

Actual values are set per business requirement. Procedures must be documented **and tested** — not just written down.

---

## 21. Documentation & Runbooks

A central internal DevOps documentation repository should cover: architecture, infrastructure, servers, DNS, domains, applications, databases, backups, monitoring, alerts, security, deployment, rollback, disaster recovery, incident response, onboarding, offboarding, and troubleshooting.

**Every production system needs a basic runbook**, e.g.:

```text
Application is down
   → Check Cloudflare
   → Check Dokploy
   → Check application health
   → Check logs
   → Check database
   → Check infrastructure
   → Rollback if necessary
```

---

## 22. Standard for New Applications

Every new application must meet this contract at minimum:

```text
GitHub repository        Logging
Dockerfile                Error tracking
CI pipeline                Monitoring
Health endpoint              Backup strategy
Environment configuration      Domain
Database migration strategy      Deployment configuration
                                    Rollback strategy
```

This keeps every application inside the standard platform instead of becoming a one-off DevOps project.

### Provisioning a new application (target future state)

```text
Create Application → Repository → Select Technology → Select Environment →
Assign Domain → Create Database → Configure Secrets → Configure Coder Template →
Configure CI/CD → Create GHCR Repository → Create Dokploy Application →
Configure Monitoring → Deploy
```

Much of this sequence should eventually be automated/templated.

---

## 23. Migration Roadmap

| Phase | Goal | Key Actions |
|---|---|---|
| **1. Audit** | Understand what exists | Inventory apps, domains, DNS, databases, cron jobs, SSL, email deps, file storage, existing deploy processes, backups. *Do not migrate anything before its dependencies are understood.* |
| **2. Foundation** | Build the platform | Set up Cloudflare, GitHub standards, server hardening, Dokploy, GHCR, monitoring, backup strategy |
| **3. Development Platform** | Move dev workflows | Deploy Coder, build standardized templates per stack, migrate developers to remote workspaces |
| **4. Staging** | Prove the pipeline | Move one low-risk application through GitHub → CI → GHCR → Dokploy → Staging |
| **5. Production** | Migrate app by app | Per app: Backup → Deploy → DNS switch → Monitor → Validate |
| **6. Database Migration** | Move to managed DBs | Verify data integrity, app connectivity, backup, restore, performance |
| **7. Decommission** | Retire cPanel | Only after every dependency has been migrated and validated |

**Current position:** Phase 2 (Foundation) — Cloudflare account created. Next actions tracked in `devops-implementation-tracker.md` §2.

---

## 24. Appendix: References

- Cloudflare WAF — [developers.cloudflare.com/waf](https://developers.cloudflare.com/waf/get-started/)
- Coder Docs — [coder.com/docs](https://coder.com/docs/index)
- Coder Templates — [coder.com/docs/admin/templates](https://coder.com/docs/admin/templates)
- Coder Workspace Lifecycle — [coder.com/docs/user-guides/workspace-lifecycle](https://coder.com/docs/user-guides/workspace-lifecycle)
- Dokploy Rollbacks — [docs.dokploy.com/docs/core/applications/rollbacks](https://docs.dokploy.com/docs/core/applications/rollbacks)
