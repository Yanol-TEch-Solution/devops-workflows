#!/usr/bin/env bash
# provision-db.sh PROJECT  — create <project>_prod + <project>_user on the shared MySQL.
# Prints Infisical-ready values at the end. Idempotent-ish: reuses an existing
# user (resets its password to a NEW generated one only with --rotate).
#
# Usage: provision-db.sh <project> [--rotate]
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROJECT="${1:?usage: provision-db.sh <project> [--rotate]}"
ROTATE="${2:-}"
DB="${PROJECT}_prod"; USER="${PROJECT}_user"
PW="$(gen_pw)"

SQL="CREATE DATABASE IF NOT EXISTS \`$DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$USER'@'%' IDENTIFIED BY '$PW';
GRANT ALL PRIVILEGES ON \`$DB\`.* TO '$USER'@'%';
FLUSH PRIVILEGES;"
[ "$ROTATE" = "--rotate" ] && SQL="ALTER USER '$USER'@'%' IDENTIFIED BY '$PW';
$SQL"

[ "${DRY_RUN:-0}" = "1" ] && { echo "--- DRY RUN: SQL that would run:"; echo "$SQL"; exit 0; }

log "creating $DB + $USER on shared-mysql ($SHARED_MYSQL_HOST)..."
printf '%s\n' "$SQL" | ssh_vps "docker exec -i \$(docker ps -q --filter name=mysql-hack | head -1) sh -c 'MYSQL_PWD=$SHARED_MYSQL_ROOT_PW mysql -uroot'"
[ "$ROTATE" = "--rotate" ] && log "password rotated for existing user."

# verify
N=$(echo "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name='$DB';" |
    ssh_vps "docker exec -i \$(docker ps -q --filter name=mysql-hack | head -1) sh -c 'MYSQL_PWD=$SHARED_MYSQL_ROOT_PW mysql -uroot -N'" 2>/dev/null)
[ "$N" = "1" ] || die "verification failed — $DB not found on shared-mysql"

log "done. Paste into Infisical under /$PROJECT/backend (or equivalent):"
cat <<EOF

  DB_HOST=$SHARED_MYSQL_HOST
  DB_PORT=3306
  DB_NAME=$DB
  DB_USER=$USER
  DB_PASSWORD=$PW
  DATABASE_URL=mysql://$USER:$PW@$SHARED_MYSQL_HOST:3306/$DB

EOF
log "keep this output out of git. Values also belong in credentials.md only if needed for break-glass."
