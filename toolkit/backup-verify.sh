#!/usr/bin/env bash
# backup-verify.sh  — read-only: shows configured DB backups + last backup
# activity from Dokploy's logs. Nightly schedule fires at 02:00 UTC to R2
# (bucket abeselom-backup; prefixes shared-mysql-backups / emahus-backups /
# billing-backups). Files land under <prefix>/ in the bucket.
set -euo pipefail
source "$(dirname "$0")/common.sh"

log "configured backup schedules:"
ssh_vps "P=\$(docker ps -q --filter name=dokploy-postgres | head -1); \
  docker exec \$P psql -U dokploy -d dokploy -c 'SELECT prefix, schedule, enabled FROM backup ORDER BY prefix;'" 2>/dev/null

log "backup activity in the last 24h (empty = none fired yet):"
ssh_vps "docker service logs dokploy --since 24h 2>&1 | grep -iE 'backup.*(success|fail|error|start)|mysqldump|rclone' | tail -10" 2>/dev/null || echo "  (no activity — check after 02:00 UTC)"

log "manual verification tip: list recent objects in R2 under the prefixes above
  (bucket abeselom-backup) or download the newest file and run gzip -t on it."
