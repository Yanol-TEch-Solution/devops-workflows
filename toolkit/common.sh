# common.sh — shared config loading + API helpers for the yanol dev-ops toolkit.
# Source this from the other scripts:  source "$(dirname "$0")/common.sh"
#
# All credentials are read from ../credentials.md (gitignored). Never hardcode.

set -euo pipefail

TOOLKIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED_FILE="${CRED_FILE:-$TOOLKIT_DIR/../credentials.md}"

# ── config parsing ────────────────────────────────────────────────────────────
# cred_get KEY  -> prints the value of KEY=value from credentials.md
cred_get() {
  sed -n "s/^$1=//p" "$CRED_FILE" | head -1 | sed 's/ *([^)]*)$//' | tr -d ' '
}

DOKPLOY_URL="${DOKPLOY_URL:-https://dokploy.yanoltech.com}"
DOKPLOY_KEY="${DOKPLOY_KEY:-$(cred_get DOKPLOY-VPS1-API-KEY)}"
# Infisical: EACH product has its OWN project (liyana, emahushosting).
# Scripts resolve the right project id from the project's state file
# (state/<project>.env: infisicalProjectId=...). INFISICAL_PROJECT is only a
# fallback for legacy calls.
INFISICAL_PROJECT="${INFISICAL_PROJECT:-$(cred_get INFISICAL-PROJECT-ID)}"
INFISICAL_CLIENT_ID="${INFISICAL_CLIENT_ID:-$(cred_get INFISICAL-CLIENT-ID)}"
INFISICAL_CLIENT_SECRET="${INFISICAL_CLIENT_SECRET:-$(cred_get INFISICAL-CLIENT-SECRET)}"
GITHUB_APP_ID="${GITHUB_APP_ID:-ogjLjeKl769Aj0y3v5o0D}"
GITHUB_OWNER="${GITHUB_OWNER:-Yanol-TEch-Solution}"
VPS_HOST="${VPS_HOST:-65.86.32.81}"
VPS_USER="${VPS_USER:-root}"
SHARED_MYSQL_HOST="mysql-hack-neural-application-mhksas"   # DB_HOST for all apps
SHARED_MYSQL_ROOT_PW="$(cred_get SHARED-MYSQL-ROOT-PASSWORD)"
BACKUP_DESTINATION_ID="$(cred_get BACKUP-DESTINATION-ID)"
STATE_DIR="$TOOLKIT_DIR/state"
mkdir -p "$STATE_DIR"

# ── Dokploy API ───────────────────────────────────────────────────────────────
# dk_api METHOD PATH [JSON_BODY]  -> raw response
dk_api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -s -X "$method" -H "x-api-key: $DOKPLOY_KEY" -H "Content-Type: application/json" \
      -d "$body" "$DOKPLOY_URL/api/$path"
  else
    curl -s -X "$method" -H "x-api-key: $DOKPLOY_KEY" "$DOKPLOY_URL/api/$path"
  fi
}

# ── Infisical API ─────────────────────────────────────────────────────────────
inf_token() {
  curl -s -X POST -H "Content-Type: application/json" \
    -d "{\"clientId\":\"$INFISICAL_CLIENT_ID\",\"clientSecret\":\"$INFISICAL_CLIENT_SECRET\"}" \
    https://app.infisical.com/api/v1/auth/universal-auth/login |
    python3 -c "import json,sys; print(json.load(sys.stdin)['accessToken'])"
}

# inf_api TOKEN METHOD PATH JSON_BODY
inf_api() {
  local token="$1" method="$2" path="$3" body="${4:-}"
  if [ -n "$body" ]; then
    curl -s -X "$method" -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
      -d "$body" "https://app.infisical.com$path"
  else
    curl -s -X "$method" -H "Authorization: Bearer $token" "https://app.infisical.com$path"
  fi
}

# inf_batch_secrets TOKEN PROJECT_ID SECRET_PATH KEY1=VAL1 [KEY2=VAL2 ...]
inf_batch_secrets() {
  local token="$1" project="$2" path="$3"; shift 3
  local payload="[" first=1
  for kv in "$@"; do
    local k="${kv%%=*}" v="${kv#*=}"
    [ $first -eq 0 ] && payload+=","
    payload+="$(python3 -c "import json,sys; print(json.dumps({'secretKey': sys.argv[1], 'secretValue': sys.argv[2]}))" "$k" "$v")"
    first=0
  done
  payload+="]"
  inf_api "$token" POST "/api/v4/secrets/batch" \
    "{\"projectId\":\"$project\",\"environment\":\"prod\",\"secretPath\":\"$path\",\"secrets\":$payload}"
}

# ── SSH to the VPS ────────────────────────────────────────────────────────────
# Uses the local askpass helper when present, else plain ssh (key auth).
ssh_vps() {
  local askpass="$HOME/.ssh/askpass/$VPS_HOST.sh"
  if [ -x "$askpass" ]; then
    SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force DISPLAY=dummy ssh -o StrictHostKeyChecking=accept-new "$VPS_USER@$VPS_HOST" "$@"
  else
    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$VPS_USER@$VPS_HOST" "$@"
  fi
}

# gen_pw  -> 28-char alphanumeric password
gen_pw() { openssl rand -base64 24 | tr -d "/+=" | head -c 28; }

# state helpers: state_get PROJECT KEY / state_set PROJECT KEY VALUE
state_file() { echo "$STATE_DIR/$1.env"; }
state_get() { [ -f "$(state_file "$1")" ] && grep -E "^$2=" "$(state_file "$1")" | head -1 | cut -d= -f2- || true; }
state_set() {
  local f="$(state_file "$1")" key="$2" val="$3"
  touch "$f"; chmod 600 "$f"
  grep -qE "^$key=" "$f" && sed -i "s|^$key=.*|$key=$val|" "$f" || echo "$key=$val" >> "$f"
}

log()  { printf "\033[36m[toolkit]\033[0m %s\n" "$*"; }
die()  { printf "\033[31m[toolkit] ERROR:\033[0m %s\n" "$*" >&2; exit 1; }
