# Template — copy to credentials.md and fill in. credentials.md is gitignored.
# Canonical local copy lives on Abeselom's machine; treat as break-glass.

DOKPLOY-URL=https://dokploy.yanoltech.com/
DOKPLOY-KEY=<dokploy api key>

# ── Servers / SSH ──
# VPS 1 — production (galasahost, 8c/16GB/320GB)
VPS-SSH-HOST=65.86.32.81
VPS-SSH-USER=root
VPS-SSH-PASSWORD=<password>
# VPS 2 — old server (alias: local-ssh-connect in ~/.zshrc) — archive only
OLD-SSH-HOST=23.88.60.140

# ── Shared MySQL (one instance, db+user per project) ──
SHARED-MYSQL-HOST=mysql-hack-neural-application-mhksas
SHARED-MYSQL-ROOT-PASSWORD=<password>

# ── Dokploy on VPS 1 ──
DOKPLOY-VPS1-API-KEY=<key>
GITHUB-APP-ID=<github app id>
GITHUB-OWNER=Yanol-TEch-Solution

# ── SELF-HOSTED Infisical (PRIMARY) — infisical.yanoltech.com ──
SELFHOST-INFISICAL-URL=https://infisical.yanoltech.com
SELFHOST-INFISICAL-ADMIN-EMAIL=<admin email>
SELFHOST-INFISICAL-ADMIN-PASSWORD=<admin password>
SELFHOST-INFISICAL-CLIENT-ID=<machine identity client id>
SELFHOST-INFISICAL-CLIENT-SECRET=<machine identity client secret>
SELFHOST-INFISICAL-ORG-ID=<org id>
SELFHOST-LIYANA-PROJECT-ID=<project id>
SELFHOST-EMAHUS-PROJECT-ID=<project id>
# ENCRYPTION_KEY/AUTH_SECRET/POSTGRES_PASSWORD live in infisical-compose.yml

# ── Infisical CLOUD (break-glass / legacy) ──
INFISICAL-SITE-URL=https://app.infisical.com
INFISICAL-LOGIN-EMAIL=<login>
INFISICAL-LOGIN-PASSWORD=<password>
INFISICAL-CLIENT-ID=<machine identity id>
INFISICAL-CLIENT-SECRET=<machine identity secret>
INFISICAL-ORG-ID=<org id>
INFISICAL-PROJECT-ID=<legacy medischedule-v2 project id>

# ── Cloudflare R2 (S3 backups) ──
R2-BUCKET=abeselom-backup
R2-ENDPOINT=https://<account>.r2.cloudflarestorage.com
R2-ACCESS-KEY-ID=<id>
R2-SECRET-ACCESS-KEY=<secret>
R2-API-TOKEN=<cfat_...>

# ── Backup schedule rows (Dokploy DB) + destination ──
BACKUP-DESTINATION-ID=<destination id>
# prefixes: shared-mysql-backups (liyana_prod), emahus-backups (emahus_prod),
#           billing-backups (billing_prod), infisical-backups (host cron 02:30)

# ── Project state (mirror of toolkit/state/*.env) ──
# liyana:    projectId / environmentId / backend-web-admin ids+appNames / infisicalProjectId
# emahus:    projectId / environmentId / backend-frontend-billing ids+appNames / infisicalProjectId

# ── Email (Emahus backend SMTP, via fra2 cPanel) ──
EMAHUS-SMTP-HOST=fra2.hostclusters.com
EMAHUS-SMTP-PORT=465
EMAHUS-SMTP-USER=no-reply@emahushosting.com
EMAHUS-SMTP-PASSWORD=<password>
EMAHUS-MAIL-FROM=Emahus Hosting <no-reply@emahushosting.com>
