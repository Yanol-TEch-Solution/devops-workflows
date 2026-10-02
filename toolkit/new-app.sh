#!/usr/bin/env bash
# new-app.sh PROJECT APP_NAME REPO BUILD_PATH [--branch BRANCH] [--port PORT] [--secrets-file FILE]
#
# Creates a Dokploy application wired end-to-end:
#   app -> GitHub source (buildPath) -> Dockerfile build -> Infisical folder
#   -> vault provider -> env with ${{vault.*}} refs for every secret in the folder.
#
# Secrets: pass --secrets-file KEY=VALUE lines, or add them later via Infisical
# and re-run with --env-only to (re)write the app env from the folder's keys.
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROJECT="${1:?usage: new-app.sh PROJECT APP_NAME REPO BUILD_PATH [--branch main] [--port N] [--secrets-file FILE] [--env-only]}"
APP="${2:?}"; REPO="${3:?}"; BUILD_PATH="${4:?}"; shift 4
BRANCH=main; PORT=5000; SECRETS_FILE=""; ENV_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --branch) BRANCH="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --secrets-file) SECRETS_FILE="$2"; shift 2;;
    --env-only) ENV_ONLY=1; shift;;
    *) die "unknown arg: $1";;
  esac
done

PID=$(state_get "$PROJECT" projectId); EID=$(state_get "$PROJECT" environmentId)
IPID=$(state_get "$PROJECT" infisicalProjectId)
INFISICAL_PROJECT="${IPID:-$INFISICAL_PROJECT}"
[ -n "$PID" ] && [ -n "$EID" ] || die "no state for project '$PROJECT' — run new-project.sh first"

# 1. application
R=$(dk_api POST application.create "{\"name\":\"$APP\",\"environmentId\":\"$EID\"}")
APPID=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['applicationId'])")
APPNAME=$(echo "$R" | python3 -c "import json,sys; print(json.load(sys.stdin)['appName'])")
[ -n "$APPID" ] || die "application.create failed: $R"
log "app created: $APP (applicationId=$APPID, appName=$APPNAME)"

# 2. git source (GitHub App)
dk_api POST application.saveGithubProvider "{\"applicationId\":\"$APPID\",\"githubId\":\"$GITHUB_APP_ID\",\"owner\":\"$GITHUB_OWNER\",\"repository\":\"$REPO\",\"branch\":\"$BRANCH\",\"buildPath\":\"$BUILD_PATH\"}" >/dev/null
log "git source: $GITHUB_OWNER/$REPO@$BRANCH buildPath=$BUILD_PATH"

# 3. build type — NOTE: the three trailing fields are REQUIRED (non-optional) even when empty
dk_api POST application.saveBuildType "{\"applicationId\":\"$APPID\",\"buildType\":\"dockerfile\",\"dockerfile\":\"Dockerfile\",\"dockerContextPath\":\"$BUILD_PATH\",\"dockerBuildStage\":\"\",\"herokuVersion\":\"\",\"railpackVersion\":\"\"}" >/dev/null
log "build type: dockerfile (context=$BUILD_PATH)"

# 4. Infisical folder
TOKEN=$(inf_token)
inf_api "$TOKEN" POST /api/v2/folders "{\"projectId\":\"$INFISICAL_PROJECT\",\"environment\":\"prod\",\"name\":\"$APP\",\"path\":\"/$PROJECT\"}" >/dev/null
log "infisical folder: /$PROJECT/$APP"

# 5. vault provider assigned to this project+environment
VP=$(dk_api POST vaultProvider.create "{\"name\":\"infisical-$PROJECT-$APP\",\"config\":{\"providerType\":\"infisical\",\"siteUrl\":\"https://app.infisical.com\",\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\",\"projectId\":\"$INFISICAL_PROJECT\",\"environmentSlug\":\"prod\",\"secretPath\":\"/$PROJECT/$APP\"},\"assignments\":[{\"projectId\":\"$PID\",\"environmentIds\":[\"$EID\"]}]}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('vaultProviderId',''))")
[ -n "$VP" ] || die "vaultProvider.create failed"
log "vault provider: infisical-$PROJECT-$APP ($VP)"

# 6. secrets -> folder (optional file with KEY=VALUE lines)
if [ -n "$SECRETS_FILE" ]; then
  mapfile -t KVS < <(grep -vE '^\s*(#|$)' "$SECRETS_FILE")
  R=$(inf_batch_secrets "$TOKEN" "/$PROJECT/$APP" "${KVS[@]}")
  N=$(echo "$R" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('secrets',[])))" 2>/dev/null || echo 0)
  log "loaded $N secrets into /$PROJECT/$APP"
fi

# 7. app env = vault ref for every key in the folder (skip with ENV_ONLY=0 when empty)
KEYS=$(inf_api "$TOKEN" GET "/api/v3/secrets/raw?workspaceId=$INFISICAL_PROJECT&environment=prod&secretPath=/$PROJECT/$APP" | python3 -c "import json,sys; print('\n'.join(s['secretKey'] for s in json.load(sys.stdin).get('secrets',[])))")
if [ -n "$KEYS" ]; then
  ENVSTR=""
  while IFS= read -r k; do [ -n "$k" ] && ENVSTR+="$k=\${{vault.infisical-$PROJECT-$APP.$k}}
"; done <<< "$KEYS"
  python3 - "$DOKPLOY_KEY" "$APPID" "$ENVSTR" <<'PYEOF'
import json, sys, urllib.request
key, appid, env = sys.argv[1], sys.argv[2], sys.argv[3]
body = {"applicationId": appid, "env": env, "buildArgs": "", "buildSecrets": "", "createEnvFile": False}
req = urllib.request.Request("https://dokploy.yanoltech.com/api/application.saveEnvironment", method="POST",
    data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "x-api-key": key})
print(urllib.request.urlopen(req, timeout=30).read()[:30])
PYEOF
  log "app env written with $(echo "$KEYS" | grep -c .) vault refs"
else
  log "folder empty — no env written yet. Add secrets, then re-run with --env-only"
fi

state_set "$PROJECT" "${APP}Id" "$APPID"
state_set "$PROJECT" "${APP}Name" "$APPNAME"
state_set "$PROJECT" "${APP}Port" "$PORT"
cat <<EOF

Next steps:
  ./deploy.sh $PROJECT $APP --watch      # first build + start
  Add a domain:  dashboard -> $APP -> Domains  (or domain.create via API)
  Add a backup:  ./backup-verify.sh          (schedule already covers shared-mysql)

EOF
