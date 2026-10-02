#!/usr/bin/env bash
# new-project.sh NAME  — create a Dokploy project + save its IDs to local state.
# The state file (state/<name>.env) is used by new-app.sh / deploy.sh.
set -euo pipefail
source "$(dirname "$0")/common.sh"

NAME="${1:?usage: new-project.sh <name>}"
[ -f "$(state_file "$NAME")" ] && die "state/$NAME.env already exists — project probably created. Remove the file to re-create."

R=$(dk_api POST project.create "{\"name\":\"$NAME\"}")
PID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['project']['projectId'])")
EID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['environment']['environmentId'])")
[ -n "$PID" ] && [ -n "$EID" ] || die "project.create failed: $R"

state_set "$NAME" projectId "$PID"
state_set "$NAME" environmentId "$EID"

# Infisical project (per-product secrets store)
TOKEN=$(inf_token)
R=$(inf_api "$TOKEN" POST /api/v1/projects "{\"organizationId\":\"$(cred_get INFISICAL-ORG-ID)\",\"projectName\":\"$NAME\"}")
IPID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['project']['id'])" 2>/dev/null || true)
if [ -n "$IPID" ]; then
  state_set "$NAME" infisicalProjectId "$IPID"
  log "infisical project '$NAME' created ($IPID)"
else
  log "WARN: Infisical project creation failed — create '$NAME' in the UI and add"
  log "  infisicalProjectId=<id> to state/$NAME.env"
fi
log "project '$NAME' created (projectId=$PID, environmentId=$EID). State: state/$NAME.env"
log "next: ./new-app.sh $NAME <app-name> <repo> <build-path> [--secrets-file keys.env]"
