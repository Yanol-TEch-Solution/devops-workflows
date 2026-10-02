# AGENTS.md — for AI agents operating the yanol infrastructure

You are working on LIVE production infrastructure. Read this file fully before
running anything. The human-readable runbook is `RUNBOOK.md`; all secrets and
IDs are in `credentials.md` (local only — NEVER commit, paste into chat only
when the operator asks, never send to third parties).

## Prime directives

1. **Read-only first.** Inspect (`docker ps`, `docker service logs`, `curl`) before
   any mutation. One mutation per step, verify after each.
2. **Never delete.** Stop/pause instead. Specifically NEVER remove: the old liyana
   containers, volume `backend_db_data` (pre-migration DB copy), the old server
   23.88.60.140's apps or volumes, any R2 object, any backup dump in `backup/`.
3. **Live sites are sacred.** liyanahealthcare.com and emahushosting.com serve
   real users. Changes that could affect them: explain plan → get operator OK →
   execute → verify → report. Off-hours changes still need verification after.
4. **Secrets never touch git, images, or build contexts.** Secrets live in
   Infisical; repos carry `.env.example` placeholders only. If you find a secret
   in a diff, stop and flag it.
5. **No git commits/pushes to project repos unless the operator explicitly asked
   in the current task.** The dev-ops folder is a local git repo with NO remote —
   keep it that way unless told otherwise.
6. **One command at a time on the server.** No fire-and-forget loops that mutate
   state. Background long builds, but verify completion before moving on.

## Architecture in 15 seconds

- VPS 65.86.32.81: Docker Swarm + Dokploy (dashboard https://dokploy.yanoltech.com,
  API with key from credentials.md) + Traefik (80/443) + shared MySQL
  (`mysql-hack-neural-application-mhksas`, no public port).
- Apps are built FROM SOURCE by Dokploy (GitHub App `ogjLjeKl769Aj0y3v5o0D`,
  org Yanol-TEch-Solution). Projects: `liyana` (backend/web/admin),
  `emahus` (backend/frontend/billing).
- Secrets: Infisical (app.infisical.com) — **one Infisical project per product**
  (`liyana`, `emahushosting`; free tier caps 3 projects / 5 identities — we are at
  3/3 projects), folders per app inside each, injected at deploy via
  `${{vault.<providerName>.<KEY>}}` refs in each app's env. The automation
  identity (credentials.md) is admin on all projects.
- Databases: shared MySQL, one `<project>_prod` db + `<project>_user` per project,
  users granted only their own schema. Nightly 02:00 UTC dumps → R2.
- Old server 23.88.60.140: reference only; its apps are scaled to 0.

## How to do common things (use the toolkit)

```bash
cd dev-ops/toolkit
./provision-db.sh <project>            # new project database + user
./new-project.sh <name>                # Dokploy project (state saved to state/)
./new-app.sh <project> <app> <repo> <build-path> [--secrets-file f] [--port N]
./deploy.sh <project> <app> --watch    # ALWAYS use --watch on first deploys
./backup-verify.sh                     # read-only
```

Source `common.sh` for helpers (`cred_get`, `dk_api`, `inf_api`, `ssh_vps`,
`state_get/set`). Add new scripts to this folder, follow the same style, and
update RUNBOOK.md in the same change.

## Non-obvious behaviors (memorize)

- **Swarm rollback**: a failing task silently reverts the service to the previous
  spec; deploys still report "done". If an env change "doesn't stick", the task
  is crash-looping — check `docker service ps` + logs, fix the value, redeploy.
- **Build-time frontend vars** (`VITE_*`, `NEXT_PUBLIC_*`): must be `ARG`s in the
  Dockerfile and passed via app `buildArgs`, or they are silently dropped.
- **Cloudflare orange-cloud breaks mail hostnames** (SMTP is not proxied) —
  mail/`cpanel`/`whm` style records must be DNS-only.
- **Infisical**: folder must exist before secrets; refs fail deployment if the
  provider isn't assigned to the app's project+environment.
- **`dockerContextPath` is repo-root-relative; `dockerfile` is buildPath-relative.**

## When something is broken

Triage order: (1) `docker service ls` — anything not 1/1? (2) `docker service
logs <name> | tail -30` (3) `docker service ps <name>` for restart/rollback
loops (4) Traefik: `docker logs dokploy-traefik | tail` (5) DNS: `dig <host>`.
Site-wide outage with no obvious cause: check whether Traefik is up, then fall
back per RUNBOOK "Deploy / rollback". Report what you find before fixing beyond
the obvious.
