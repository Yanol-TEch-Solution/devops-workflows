#!/usr/bin/env bash
# deploy.sh PROJECT APP [--watch]
#
# Triggers a Dokploy deployment and (with --watch) waits until the swarm task
# is Running. IMPORTANT: Dokploy sets failureAction=rollback, so a crashing
# task silently reverts to the previous env — if a config change "doesn't
# apply", the task is probably crash-looping. This script surfaces that.
set -euo pipefail
source "$(dirname "$0")/common.sh"

PROJECT="${1:?usage: deploy.sh PROJECT APP [--watch]}"; APP="${2:?}"; WATCH="${3:-}"
APPID=$(state_get "$PROJECT" "${APP}Id"); APPNAME=$(state_get "$PROJECT" "${APP}Name")
[ -n "$APPID" ] || { APPID="$APP"; APPNAME=""; }   # allow raw applicationId

R=$(dk_api POST application.deploy "{\"applicationId\":\"$APPID\"}")
echo "$R" | grep -q Not && die "deploy trigger failed: $R"
log "deploy triggered for $APP"

[ "$WATCH" != "--watch" ] && exit 0
[ -n "$APPNAME" ] || die "--watch needs the app's state (appName) — pass raw id without --watch, or fix state file"

sleep 15
for i in $(seq 1 30); do
  ST=$(ssh_vps "docker service ps $APPNAME --format '{{.CurrentState}}' 2>/dev/null | head -1")
  echo "[$((i*20))s] $ST"
  case "$ST" in
    Running*) log "task is Running."; exit 0;;
    Failed*|Rejected*)
      log "task FAILED and swarm may have ROLLED BACK to the previous env."
      log "check why before redeploying:  ssh_vps 'docker service logs $APPNAME | tail -30'"
      log "(most common cause: an invalid credential pair or bad env value.)"
      exit 1;;
  esac
  sleep 20
done
die "timed out waiting for Running — inspect on the server."
