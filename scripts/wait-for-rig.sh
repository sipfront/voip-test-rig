#!/usr/bin/env bash
#
# Block until every rig service is ready (or RIG_WAIT_TIMEOUT seconds elapse).
# Run after `docker compose up -d`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Load .env (for MYSQL_ROOT_PASSWORD etc.) if present.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

COMPOSE=(docker compose)
TIMEOUT="${RIG_WAIT_TIMEOUT:-240}"
deadline=$(( $(date +%s) + TIMEOUT ))

wait_for() {
  local name="$1"; shift
  printf 'waiting for %-11s ... ' "${name}"
  while true; do
    if "$@" >/dev/null 2>&1; then echo "ok"; return 0; fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "TIMEOUT"
      "${COMPOSE[@]}" logs --tail=30 "${name}" || true
      return 1
    fi
    sleep 3
  done
}

# MySQL over TCP (only succeeds once initdb has finished and the real server is up)
wait_for mysql "${COMPOSE[@]}" exec -T mysql \
  mysqladmin ping -h 127.0.0.1 -p"${MYSQL_ROOT_PASSWORD:-rigrootpw}"

# Kamailio: control socket answers once the config loaded successfully
wait_for kamailio "${COMPOSE[@]}" exec -T kamailio kamcmd core.uptime

# rtpengine: prints this line once interfaces are bound and it's ready
rtpengine_ready() { "${COMPOSE[@]}" logs rtpengine 2>&1 | grep -q "Startup complete"; }
wait_for rtpengine rtpengine_ready

# Asterisk: the CLI answers on the control socket once it's fully booted
wait_for asterisk "${COMPOSE[@]}" exec -T asterisk asterisk -rx "core show uptime"

echo "rig is ready"

# ---- jambonz Voice-AI stack (best-effort) --------------------------------
# Only checked when the "voicebot" compose profile is up (i.e. `make voicebot`);
# the default rig doesn't start it. Readiness is NON-FATAL even then.
if "${COMPOSE[@]}" ps --services --filter status=running 2>/dev/null | grep -qx feature-server; then
  jambonz_deadline=$(( $(date +%s) + ${JAMBONZ_WAIT_TIMEOUT:-180} ))
  jwait() {
    local name="$1"; shift
    printf 'waiting for %-13s ... ' "${name}"
    while true; do
      if "$@" >/dev/null 2>&1; then echo "ok"; return 0; fi
      if [ "$(date +%s)" -ge "${jambonz_deadline}" ]; then echo "not ready (non-fatal)"; return 0; fi
      sleep 3
    done
  }
  # feature-server: HTTP health port answers once it's connected to drachtio/FS/DB
  jwait feature-server "${COMPOSE[@]}" exec -T feature-server \
    node -e 'require("http").get("http://127.0.0.1:3000/",r=>process.exit(r.statusCode<500?0:1)).on("error",()=>process.exit(1))'
  # voicebot app: websocket server listening
  jwait voicebot "${COMPOSE[@]}" exec -T voicebot \
    node -e 'require("http").get("http://127.0.0.1:3000/",r=>process.exit(0)).on("error",()=>process.exit(1))'
  echo "jambonz checked"
fi
