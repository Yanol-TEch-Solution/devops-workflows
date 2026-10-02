# Dokploy Consistency Plan — Reconcile Deployment with Documentation

**Created:** 2026-09-03
**Source audit:** `/tmp/dokploy-audit/` (Dokploy API dumps + live domain probes)
**Goal:** Make the deployed state on Dokploy match what the documentation claims, and fix all broken domains/routes/configs identified in the audit.

---

## Audit Findings (summary)

9 categories of inconsistency were found between the Dokploy deployment and the documentation in `docs/`:

1. 5 projects live in production but marked "Pending" in the tracker
2. All 8 `*.liyanahealthcare.com` domains have broken TLS (self-signed Traefik cert)
3. All 6 `galasahost.com` prod/staging domains are redirect loops (Emahus prod idle)
4. gelan-pms production builds from `staging` branch instead of `main`
5. yanet-general staging/dev composes pull `main` branch (environment isolation broken)
6. 6 live services lack the mandated `/api/health` endpoint
7. E-Service production compose is idle (domain returns bare 404)
8. Dev environments claimed live but are idle or have no domain configured
9. Emahus dev apps serve billing data over plain HTTP

---

## Plan

### Item 1: Create missing staging + dev environments

**Projects:** qirb-alga, gelan-pms, medischedule-v2, yanet-primary-hospital

**Current state:**
- qirb-alga: production only (no staging/dev env exists)
- gelan-pms: production only (no staging/dev env exists)
- medischedule-v2: prod done, staging + dev composes exist but `idle`
- yanet-primary-hospital: prod done, staging + dev composes exist but `idle`

**Actions:**
- For qirb-alga and gelan-pms: create staging + development environments in Dokploy, create compose apps with domains `staging-<project>.yanoltech.com` and `dev-<project>.yanoltech.com`
- For medischedule-v2 and yanet-primary: staging/dev composes already exist with domains configured — deploy them
- Migrations run automatically on boot (verified: all 4 have entrypoint scripts that run `prisma migrate deploy` / `php artisan migrate` / `sequelize-cli db:migrate`)
- Verify each new environment responds on its domain and `/api/health` returns 200

**Verification:**
- `curl -s https://staging-qirbalga.yanoltech.com/api/health` returns 200
- `curl -s https://dev-qirbalga.yanoltech.com/api/health` returns 200
- Same for gelan, medischedule, yanet-primary

---

### Item 2: Fix liyanahealthcare.com TLS via Cloudflare SSL for SaaS

**Current state:** 8 `*.liyanahealthcare.com` domains are configured in Dokploy but TLS is broken. The zone uses `hostns.io` nameservers (not Cloudflare). A records resolve to the VPS (`23.88.60.140`). Traefik serves the self-signed `TRAEFIK DEFAULT CERT` — Let's Encrypt never issued. HTTP 308-redirects to HTTPS, which fails cert validation.

**Constraint:** No access to hostns.io. Only cPanel zone editor access for `liyanahealthcare.com`.

**Actions:**
1. In the existing Cloudflare account (the one managing `yanoltech.com`), go to SSL/TLS → Custom Hostnames
2. Add `liyanahealthcare.com` as a custom hostname
3. Cloudflare provides a verification CNAME/TXT record
4. Add that CNAME/TXT record via the cPanel zone editor for `liyanahealthcare.com`
5. Once verified, Cloudflare proxies TLS for all `*.liyanahealthcare.com` domains at the edge
6. Add each specific hostname (`medischedule.liyanahealthcare.com`, `yanetprimary.liyanahealthcare.com`, etc.) as custom hostnames if wildcard isn't supported
7. Ensure Cloudflare SSL mode is set to "Full" or "Full (Strict)" for these custom hostnames

**Affected domains (8):**
- `medischedule.liyanahealthcare.com`
- `yanetprimary.liyanahealthcare.com`
- `yanetgeneral.liyanahealthcare.com`
- `staging-yanetgeneral.liyanahealthcare.com`
- `dev-medischedule.liyanahealthcare.com`
- `staging-medischedule.liyanahealthcare.com`
- `dev-yanetprimary.liyanahealthcare.com`
- `staging-yanetprimary.liyanahealthcare.com`

**Verification:**
- `openssl s_client -connect medischedule.liyanahealthcare.com:443 -servername medischedule.liyanahealthcare.com` shows a valid Cloudflare/LE cert (not `TRAEFIK DEFAULT CERT`)
- `curl -s https://medischedule.liyanahealthcare.com/` returns 200

---

### Item 3: Deploy Emahus production + fix galasahost.com redirect loops

**Current state:**
- 3 production apps are `idle` (never deployed): `emahus-frontend`, `emahus-backend`, `emahus-fossbilling`
- All 6 `galasahost.com` prod/staging domains return 308 redirect to self (redirect loop)
- `galasahost.com` NS is on Cloudflare (`blakely.ns.cloudflare.com`, `andronicus.ns.cloudflare.com`)
- Root cause: Cloudflare SSL mode is likely "Flexible" — Cloudflare talks to origin over HTTP, Traefik redirects HTTP→HTTPS, creating a loop

**Actions:**
1. Fix Cloudflare SSL mode for `galasahost.com` zone: change from "Flexible" to "Full" or "Full (Strict)"
2. Deploy the 3 idle production apps in Dokploy:
   - `emahus-frontend` (image: `ghcr.io/yanol-tech-solution/emahus-frontend:main`, domain: `galasahost.com`)
   - `emahus-backend` (image: `ghcr.io/yanol-tech-solution/emahus-backend:main`, domain: `api.galasahost.com`)
   - `emahus-fossbilling` (image: `fossbilling/fossbilling:latest`, domain: `billing.galasahost.com`)
3. Verify staging domains also stop looping after the SSL mode fix

**Affected domains (6):**
- `galasahost.com` (prod frontend)
- `api.galasahost.com` (prod backend)
- `billing.galasahost.com` (prod fossbilling)
- `staging.galasahost.com` (staging frontend)
- `api-staging.galasahost.com` (staging backend)
- `billing-staging.galasahost.com` (staging fossbilling)

**Verification:**
- `curl -s -o /dev/null -w "%{http_code}" https://galasahost.com/` returns 200 (not 301/308)
- `curl -s -o /dev/null -w "%{http_code}" https://api.galasahost.com/` returns 200
- `curl -s -o /dev/null -w "%{http_code}" https://billing.galasahost.com/` returns 200
- Same for staging variants

---

### Item 4: Switch gelan-pms production to `main` branch

**Current state:** `gelan-pms` compose in Dokploy has `sourceType=github`, `branch=staging`. The documented branch model says `main`=production, `staging`=staging. Production is running staging-branch code.

**Actions:**
1. Update the `gelan-pms` compose in Dokploy: change branch from `staging` to `main`
2. Redeploy the compose
3. Verify the app still serves correctly at `gpms.yanoltech.com` and `api-gpms.yanoltech.com`

**Verification:**
- `curl -s https://gpms.yanoltech.com/` returns 200 with the Gelan PMS frontend
- `curl -s https://api-gpms.yanoltech.com/` returns 200

---

### Item 5: Fix yanet-general staging/dev branch isolation

**Current state:**
- `yanet-general-staging` compose: `sourceType=github`, `branch=main` (should be `staging`)
- `yanet-general-dev` compose: `sourceType=github`, `branch=main` (should be `development`)
- Both are serving production-branch code in staging/dev environments

**Actions:**
1. Update `yanet-general-staging` compose: change branch from `main` to `staging`
2. Update `yanet-general-dev` compose: change branch from `main` to `development`
3. Redeploy both
4. Verify both still respond and serve different code than production

**Verification:**
- `curl -s https://staging-yanetgeneral.yanoltech.com/api/health` returns 200
- `curl -s https://dev-yanetgeneral.yanoltech.com/api/health` returns 200
- Confirm staging/dev serve different content than `yanetgeneral.yanoltech.com` (prod)

---

### Item 6: Add `/api/health` endpoints to 6 services

**Current state:**
- pms (frontend + backend, prod + staging): no `/api/health` endpoint (returns 404 HTML)
- gpms (frontend + backend): no `/api/health` endpoint (returns 404 HTML)
- qirbalga: no `/api/health` endpoint (returns `Cannot GET /api/health`)
- medischedule: has endpoint but wrong response shape (`{"status":"API is running"}` instead of `{"status":"ok","database":"up"}`)
- yanol landing page: no `/api/health` (exempted from this fix — it's a static landing page)

**Required response per `ONBOARDING.md`:** `{"status":"ok","database":"up"}`

**Actions:**
1. **yano-pms backend** (`api-pms.yanoltech.com`, `staging-api-pms.yanoltech.com`): add `/api/health` route that checks DB connectivity and returns `{"status":"ok","database":"up"}`
2. **gelan-pms backend** (`api-gpms.yanoltech.com`): add `/api/health` route (Laravel — add a HealthController or route in `routes/api.php`)
3. **qirbalga backend**: add `/api/health` route (Express — add a health route)
4. **medischedule backend**: update existing health endpoint response to include `"database":"up"` field
5. Deploy updated images for each

**Note:** Frontend apps (pms-frontend, gpms-frontend) don't need their own health endpoint — the backend health check covers the project. The docs say "every project" but the intent is that the backend exposes it.

**Verification:**
- `curl -s https://api-pms.yanoltech.com/api/health` returns `{"status":"ok","database":"up"}`
- `curl -s https://api-gpms.yanoltech.com/api/health` returns `{"status":"ok","database":"up"}`
- `curl -s https://qirbalga.yanoltech.com/api/health` returns `{"status":"ok","database":"up"}`
- `curl -s https://medischedule.yanoltech.com/api/health` returns `{"status":"ok","database":"up"}`

---

### Item 7: Deploy E-Service production

**Current state:** `eservice-production` compose is configured (domain `eservice.yanoltech.com`, GHCR images tagged `:production`) but status is `idle` — never deployed. The domain is live and returns a bare 404.

**Actions:**
1. Deploy the `eservice-production` compose in Dokploy
2. Verify the frontend serves at `eservice.yanoltech.com`
3. Verify `/api/health` returns 200 with `{"status":"ok","database":"up"}`
4. Verify the Nginx `/api` proxy works (frontend proxies `/api` to `eservice-backend:80`)

**Verification:**
- `curl -s https://eservice.yanoltech.com/` returns 200 (not 404)
- `curl -s https://eservice.yanoltech.com/api/health` returns `{"status":"ok","database":"up"}`

---

### Item 8: Configure domains + deploy idle dev/staging environments

**Current state:**
- `eservice-dev` compose: `idle`, no domain configured (`domains: []`), `dev-eservice.yanoltech.com` returns 404
- `president-office-dev` app: `idle`, no domain configured, `sourceType=github`, `branch=development`
- `medischedule-staging` + `medischedule-dev` composes: `idle`, domains configured but not deployed
- `yanet-primary-staging` + `yanet-primary-dev` composes: `idle`, domains configured but not deployed

**Actions:**
1. `eservice-dev`: add domain `dev-eservice.yanoltech.com` to the compose, deploy
2. `president-office-dev`: add domain (e.g. `dev-president.yanoltech.com`), deploy
3. `medischedule-staging`: deploy (domain `staging-medischedule.yanoltech.com` already configured)
4. `medischedule-dev`: deploy (domain `dev-medischedule.yanoltech.com` already configured)
5. `yanet-primary-staging`: deploy (domain `staging-yanetprimary.yanoltech.com` already configured)
6. `yanet-primary-dev`: deploy (domain `dev-yanetprimary.yanoltech.com` already configured)

**Verification:**
- `curl -s https://dev-eservice.yanoltech.com/` returns 200
- `curl -s https://dev-president.yanoltech.com/` returns 200
- `curl -s https://staging-medischedule.yanoltech.com/api/health` returns 200
- `curl -s https://dev-medischedule.yanoltech.com/api/health` returns 200
- `curl -s https://staging-yanetprimary.yanoltech.com/api/health` returns 200
- `curl -s https://dev-yanetprimary.yanoltech.com/api/health` returns 200

---

### Item 9: Enable HTTPS on Emahus dev apps

**Current state:** 3 Emahus dev apps have `https=false`:
- `emahus-dev-frontend` → `app-dev.galasahost.com` (HTTP only)
- `emahus-dev-backend` → `api-dev.galasahost.com` (HTTP only)
- `emahus-dev-fossbilling` → `billing-dev.galasahost.com` (HTTP only)

These serve billing/FossBilling data over unencrypted HTTP.

**Actions:**
1. Set `https=true` on all 3 Emahus dev apps in Dokploy
2. Ensure Let's Encrypt certs issue for the 3 dev domains
3. If LE fails (same root cause as galasahost.com SSL mode), fix Cloudflare SSL mode first (covered in Item 3)
4. Verify HTTPS works and HTTP redirects to HTTPS properly

**Verification:**
- `curl -s https://app-dev.galasahost.com/` returns 200
- `curl -s https://api-dev.galasahost.com/` returns 200
- `curl -s https://billing-dev.galasahost.com/` returns 200
- `curl -s -o /dev/null -w "%{http_code}" http://app-dev.galasahost.com/` returns 301/308 (redirect to HTTPS)

---

### Item 10: Update documentation

**Files to update:**
- `docs/devops-implementation-tracker.md`
- `docs/ONBOARDING.md` (if health endpoint standard needs clarification)
- `docs/devops-architecture.md` (if domain inventory changes)

**Changes to `devops-implementation-tracker.md`:**

1. **Section 3 (Remaining Projects):** Update status for all 5 projects:
   - qirb-alga: Pending → **Done** (production live)
   - gelan-project-management: Pending → **Done** (production live, branch fixed to main)
   - medischedule-v2: Pending → **Done** (production live, staging/dev deployed)
   - yanet-primary-hospital: Pending → **Done** (production live, staging/dev deployed)
   - yanet-general-hospital: Pending → **Done** (production live, all 3 envs live)

2. **Section 2 (Phase 3 — E-Service):** Update production deployment from "Pending" to "Done"

3. **Decisions Log:** Add entries for:
   - liyanahealthcare.com TLS fixed via Cloudflare SSL for SaaS (not NS transfer)
   - galasahost.com redirect loop fixed via Cloudflare SSL mode change (Flexible → Full)
   - gelan-pms production branch switched from staging to main
   - yanet-general staging/dev branch isolation fixed
   - Emahus production deployed
   - Emahus dev HTTPS enabled
   - Health endpoints added to pms, gpms, qirbalga; medischedule response shape fixed

4. **Section 6 (Dependency Map):** Update all project statuses to reflect actual state

5. **"Staging + dev Dokploy environments created (DONE)" claim:** Update to reflect which envs are actually deployed vs just created

6. **"liyanahealthcare.com dual domains (DONE)" claim:** Update to note TLS was broken and fixed via SSL for SaaS

7. **"Development env created at dev-eservice.yanoltech.com" claim:** Update to reflect domain was added and deployed

---

## Execution Order

| Phase | Items | Type | Dependencies |
|---|---|---|---|
| 1 | 4, 5, 9 | Config-only (Dokploy API + Cloudflare) | None |
| 2 | 2, 3 | Infrastructure (Cloudflare + Dokploy deploy) | Item 3 should be done before Item 9 verification |
| 3 | 1, 7, 8 | Deploy new apps/envs | None |
| 4 | 6 | Code changes + deploy | Can run in parallel with phase 3 |
| 5 | 10 | Documentation | After all other items verified |

---

## Constraints

- No destructive commands without explicit confirmation
- No `git commit` or `git push` (per project rules)
- No manual database migrations (all projects have auto-migrate on boot)
- No editing generated SQLC code
- Verify each change with a live domain probe before marking it done
- Update docs only after the deployed state is verified

---

## Verification Checklist (final)

After all items are complete, run this full check:

- [ ] All 41+ domains return HTTP 200 (not 404, not redirect loop, not cert error)
- [ ] All `*.liyanahealthcare.com` domains serve valid TLS certs (not TRAEFIK DEFAULT CERT)
- [ ] All `*.galasahost.com` domains serve content (not redirect loops)
- [ ] All production services have `/api/health` returning `{"status":"ok","database":"up"}`
- [ ] gelan-pms production compose uses branch `main`
- [ ] yanet-general staging uses branch `staging`, dev uses branch `development`
- [ ] E-Service production is live at `eservice.yanoltech.com`
- [ ] All dev/staging environments claimed in docs are actually deployed and reachable
- [ ] Emahus dev apps serve over HTTPS
- [ ] `docs/devops-implementation-tracker.md` matches actual Dokploy state
