# RUNBOOK — yanol infrastructure (galasahost VPS)

Last updated: 2026-09-28. Read this top-to-bottom once before touching anything.

## The one-paragraph overview

Two servers. **65.86.32.81** (a.k.a. galasahost / server.galasahost.com) runs
everything production: Docker Swarm + Dokploy dashboard (https://dokploy.yanoltech.com,
tunnel or public), Traefik on 80/443, one **shared MySQL** for all projects, and
per-project apps (currently: liyana ×3, emahus ×3). **23.88.60.140** is the OLD
server — it still runs old apps scaled to zero as reference; nothing production
depends on it. Secrets live in **Infisical** — **one Infisical project per
product** (`liyana`, `emahushosting`; free tier = 3 projects, we are at the
limit; legacy `medischedule-v2` is an archive) with folders per app — databases
are **one MySQL instance, one database + one user per project**; nightly
02:00 UTC backups go to **Cloudflare R2** (bucket `abeselom-backup`).

## Everyday commands (from `dev-ops/toolkit/`)

```bash
./provision-db.sh <project>            # create <project>_prod + user on shared MySQL
./new-project.sh <name>                # Dokploy project + local state file
./new-app.sh <project> <app> <repo> <build-path> [--port N] [--secrets-file f]
./deploy.sh <project> <app> --watch    # trigger + watch (detects crash/rollback)
./backup-verify.sh                     # schedules + last backup activity (read-only)
```

State lives in `toolkit/state/<project>.env` (IDs only, tracked in git).

## Recipe: onboard a new project (30 min)

1. `./provision-db.sh <project>` → copy the printed values
2. Infisical: create folder `/<project>/<app>` for each app (new-app.sh does it)
   and paste the DB values as secrets (`DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD/DATABASE_URL`
   + the app's own secrets: JWT, API keys…). Use the standardized names from
   `.env.example` conventions.
3. `./new-project.sh <name>` then `./new-app.sh <name> <app> <repo> <build-path>`
   for each service (frontend build args like `VITE_*/NEXT_PUBLIC_*` go in the
   app's **buildArgs** — see Gotcha #2).
4. `./deploy.sh <name> <app> --watch` — watch the FIRST deploy closely.
5. Domains: Dokploy dashboard → app → Domains (`domain.create` via API:
   `{applicationId, host, port, https: true, certificateType: "letsencrypt"}`).
   Certs auto-issue; domain must resolve here (Cloudflare: DNS record → this VPS).
6. Backups: shared-mysql schedules cover all schemas — add a `backup.create` with
   a project-specific prefix if you want separate R2 folders.
7. Write the project into `credentials.md` (IDs section) and commit the state file.

## Deploy / rollback

- **Redeploy an app:** `./deploy.sh <project> <app> --watch` (or dashboard → Redeploy).
- **App crashes after an env change:** swarm **auto-rolls-back** (Dokploy sets
  `failureAction=rollback`, 5s monitor). Symptoms: deploy says "done" but the app
  still runs old config. Diagnose: `docker service ps <appName>` (look for
  Failed/Shutdown pairs) and `docker service logs <appName> | tail -30`.
  Fix the failing env, redeploy — do NOT fight a phantom cache.
- **Emergency revival of the OLD liyana stack** (kept stopped, not removed):
  `docker start liyana_frontend liyana_backend liyana_admin liyana_db` +
  `sed -i` the three `legacy-*` service URLs in
  `/etc/dokploy/traefik/dynamic/legacy-liyana.yml` back to the old container
  names + wait 5s for Traefik to reload.
- **Emergency revival of nginx as edge** (only if Traefik itself is broken):
  `docker stop dokploy-traefik && systemctl start nginx` (nginx is disabled, not
  removed; its configs still point at the OLD containers, so also do the step above).
- **Dokploy dashboard down:** SSH tunnel `ssh -L 3002:127.0.0.1:3002 root@65.86.32.81`
  → http://localhost:3002. Check `docker service ls` (dokploy, dokploy-postgres 1/1?)
  and `docker service logs dokploy`.

## Self-hosted Infisical (PRIMARY secrets store)

- URL https://infisical.yanoltech.com (admin login in credentials.md); deployed as
  Dokploy compose in project `infrastructure` (app + Postgres + Redis, pinned v0.165.16).
- Vault providers resolve secrets via internal `http://infisical:8080` — they never
  touch Cloudflare. Cloudflare blocks scripted calls to the public URL (1010): automate
  server-side with `curl -k --resolve infisical.yanoltech.com:443:127.0.0.1 ...`.
- Its OpenAPI lives at `/api/docs/json` — check there FIRST before any API work.
- **Backup:** host cron `30 2 * * *` runs `/opt/infisical-backup/backup.py`
  (pg_dump → gzip → signed PUT to R2 `infisical-backups/`). Logs: `/var/log/infisical-backup.log`.
- **Restore drill:** verified 2026-09-28 (88 secrets, 12 folders recovered from R2 dump).
  Steps: `rclone copy r2:abeselom-backup/infisical-backups/<file> /tmp/` → restore into a
  throwaway postgres → count rows in `secrets_v2`. The dump is USELESS without
  `ENCRYPTION_KEY` from `dev-ops/infisical-compose.yml` (local only!) — keep them together.
- **Cloud Infisical (app.infisical.com)** is break-glass only — same secrets frozen as of
  2026-09-28; not referenced by production.

## Server inventory (65.86.32.81)

| Thing | What/where |
|---|---|
| Shared MySQL | swarm service `mysql-hack-neural-application-mhksas` (mysql:8.0), NO public port; root pw in credentials.md |
| Dokploy + its Postgres | swarm services `dokploy` (dashboard :3002 → container 3000), `dokploy-postgres` |
| Traefik | container `dokploy-traefik`, ports 80/443; dynamic config in `/etc/dokploy/traefik/dynamic/` |
| Liyana | apps `liyana-backend/web/admin` (project `liyana`); domains liyanahealthcare.com + www + api. + admin. |
| Emahus | apps `emahus-backend/web/billing` (project `emahus`); domains emahushosting.com + api. + billing. |
| OLD liyana stack | containers `liyana_*` — **stopped, keep for rollback**; volume `backend_db_data` = pre-migration DB copy. DO NOT prune. |
| Coder | systemd `coder.service` — **paused** (`systemctl enable --now coder` to revive) |
| qirb-db | container `qirb-db-fad794f6-…` — **paused** (`docker start` to revive) |
| Backups | R2 `abeselom-backup`: prefixes `shared-mysql-backups`, `emahus-backups`, `billing-backups` (nightly 02:00 UTC) |

23.88.60.140 (old): old Dokploy + apps scaled to 0 (tpms, house-registration,
yanet, gelan, emahus ×3, visit-bishoftu, old-qirb…). Rescue dumps for emahus are
in `backup/emahus-rescue-2026-09-27/`. Do not delete anything there without a
fresh verified backup.

## Gotchas log (learned the hard way)

1. **Swarm rollback masks bad env** — see "Deploy / rollback". If an env change
   "doesn't apply", a task is crash-looping. Always watch first deploys.
2. **`VITE_*` / `NEXT_PUBLIC_*` vars are BUILD-TIME.** They must be declared as
   `ARG` in the Dockerfile (see Liyana_web Dockerfile) AND passed via
   `buildArgs` — otherwise they are silently dropped.
3. **Cloudflare proxy (orange cloud) breaks SMTP/mail hostnames** — mail
   records (`mail.*`) must be **DNS only**. Cloudflare does not proxy SMTP ports.
4. **Infisical**: folders must exist before batch-secrets; refs are
   `${{vault.<providerName>.<KEY>}}`; a vault provider must be assigned to the
   app's project+environment or resolution throws.
5. **Dokploy API quirks**: `saveBuildType` requires `dockerBuildStage`,
   `herokuVersion`, `railpackVersion` present (empty strings OK); router is
   `vaultProvider.create` (camelCase); deploy is `application.deploy`; there is
   no `project.delete`.
6. **`dockerContextPath` is relative to the REPO ROOT**, `dockerfile` is
   relative to the buildPath. Wrong context = image builds with the wrong
   package.json (it happened).
7. **Never bake `.env` into images** — every service has a `.dockerignore`
   excluding it; secrets come from Infisical at deploy time.
8. **Shared MySQL has no public port.** Reach it via the dokploy-network or
   `docker exec` on the server. Never publish 3306.
9. **Backup rows need `mysqlId` + `database` (schema NAME) set.** The REST shim
   `backup.create` writes the service id into `database` and leaves `mysqlId`
   NULL — backups then fail silently ("Error running manual MySQL backup", no
   deployment row). Fixed 2026-09-28 by direct DB update; verify
   `SELECT "mysqlId", database FROM backup` after any API-created backup row.
   Dump files land in R2 under `mysql-hack-…/<prefix>/<timestamp>.sql.gz`.
   `backup.manualBackupMySql {backupId}` runs one immediately — use it to test.
10. **Vault ref syntax: DOUBLE braces `${{vault.<provider>.<KEY>}}`.** A single
    brace `${vault...}` passes through unresolved into the container, the app
    crashes on env validation, and swarm silently rolls back — which looks
    exactly like "my env change isn't applying". Generated with python f-strings,
    `${{` must be written `${{{{`; safest is plain string concatenation.
    Diagnose any "not applying" case: `docker service ps <name>` (Failed/Shutdown
    = crash+rollback) then read the FAILED container's logs
    (`docker inspect <cid> --format {{.Created}}` to find it).
11. **Dokploy env → swarm spec can go stale (seen 2026-09-29, billing app).**
    `saveEnvironment` returns true and `application.one` shows the new env, but
    deploys kept the OLD resolved env in the swarm spec (verify with
    `docker service inspect <app> --format '{{json .Spec.TaskTemplate.ContainerSpec.Env}}'`).
    Workaround that works: write env as literals, then — while the service is
    scaled to 0 — `docker service update --env-add K=V …` for every key and
    scale back up. Every OTHER env change (vault-rotated values) also needs this
    until the provider refresh behavior is understood.
12. **Setting ENTRYPOINT in a child Dockerfile resets the inherited CMD.**
    The billing image silently exited 0 until `CMD ["sh","-c","cron & exec
    apache2-foreground"]` was re-declared. Always re-check `docker image inspect
    … --format '{{json .Config.Cmd}}'` after adding an ENTRYPOINT.
13. **FOSSBilling containers: three installer-era files must be shipped in the
    image** (they live in ephemeral layers, `Emahus-Hosting/infra/fossbilling/`):
    `config.php` (env-driven), `themes/huraga/config/settings_data.json`
    (public theme 500s without it), and `data/update-finalization.json`
    (missing → every fresh container re-enters pending update finalization:
    maintenance mode + 500s; fix per occurrence via admin API
    `system/finalize_update` + `system/complete_update_finalization`).
    `billing_user`'s password and `FOSSBILLING_SALT` (encrypts stored server
    passwords — NEVER rotate) are in Infisical /emahus/billing.

## Credentials map

Everything is in `credentials.md` (local only, gitignored): server SSH, Dokploy
API keys (both instances), Infisical machine identity, R2 keys, DB passwords,
GitHub App id, per-app IDs. `toolkit/scripts` read from it — keep it current.
