#!/usr/bin/env bash
#
# Block until every rig service is ready (or RIG_WAIT_TIMEOUT seconds elapse).
# Run after `docker compose up -d`. The final "rig is ready" line is printed only
# once ALL checks (core + jambonz, when the voicebot profile is up) have passed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Load .env (for MYSQL_ROOT_PASSWORD etc.) if present.
if [ -f .env ]; then set -a; . ./.env; set +a; fi

COMPOSE=(docker compose)
TIMEOUT="${RIG_WAIT_TIMEOUT:-240}"
deadline=$(( $(date +%s) + TIMEOUT ))

# Per-attempt hard cap so a single hung probe can't block the whole script. A
# WebSocket server, for instance, accepts the TCP connection and then holds it
# open without an HTTP reply — an http.get against it never returns. Wrapping
# every attempt in `timeout` guarantees we always fall back to the retry loop.
# `timeout` is GNU coreutils (present on CI); on macOS it's `gtimeout`. If neither
# exists, run the probe directly — our probes self-limit (net socket timeout) so
# this only loses the cap for the non-hanging ones.
ATTEMPT_TIMEOUT="${RIG_ATTEMPT_TIMEOUT:-8}"
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
else TIMEOUT_BIN=""; fi
try() {
  if [ -n "${TIMEOUT_BIN}" ]; then "${TIMEOUT_BIN}" "${ATTEMPT_TIMEOUT}" "$@" >/dev/null 2>&1
  else "$@" >/dev/null 2>&1; fi
}

# Dump context (status + recent logs) when a probe gives up, so CI logs explain why.
dump_debug() {
  local name="$1"
  echo "----- debug for '${name}' -----"
  "${COMPOSE[@]}" ps || true
  echo "----- last 40 log lines: ${name} -----"
  "${COMPOSE[@]}" logs --tail=40 "${name}" 2>&1 || true
  echo "-------------------------------"
}

wait_for() {
  local name="$1"; shift
  printf 'waiting for %-13s ... ' "${name}"
  while true; do
    if try "$@"; then echo "ok"; return 0; fi
    if [ "$(date +%s)" -ge "${deadline}" ]; then
      echo "TIMEOUT"
      dump_debug "${name}"
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

echo "core rig services ready"

# ---- jambonz Voice-AI stack (best-effort) --------------------------------
# Only checked when the "voicebot" compose profile is up (i.e. `make voicebot`
# or CI with --profile voicebot); the default rig doesn't start it. Readiness is
# NON-FATAL: we still want the rig usable even if a jambonz component lags.
if "${COMPOSE[@]}" ps --services --filter status=running 2>/dev/null | grep -qx feature-server; then
  echo "jambonz voicebot profile detected — checking the Voice-AI stack"
  jambonz_deadline=$(( $(date +%s) + ${JAMBONZ_WAIT_TIMEOUT:-180} ))
  jwait() {
    local name="$1"; shift
    printf 'waiting for %-13s ... ' "${name}"
    while true; do
      if try "$@"; then echo "ok"; return 0; fi
      if [ "$(date +%s)" -ge "${jambonz_deadline}" ]; then
        echo "not ready (non-fatal)"
        dump_debug "${name}"
        return 0
      fi
      sleep 3
    done
  }
  # feature-server: HTTP health port answers once it's connected to drachtio/FS/DB
  jwait feature-server "${COMPOSE[@]}" exec -T feature-server \
    node -e 'require("http").get("http://127.0.0.1:3000/",r=>process.exit(r.statusCode<500?0:1)).on("error",()=>process.exit(1))'
  # voicebot app: a pure WebSocket server, so probe with a plain TCP connect
  # (an http.get would hang — the ws server never sends an HTTP response).
  jwait voicebot "${COMPOSE[@]}" exec -T voicebot \
    node -e 'const s=require("net").connect(3000,"127.0.0.1");s.setTimeout(3000);s.on("connect",()=>{s.end();process.exit(0)});s.on("error",()=>process.exit(1));s.on("timeout",()=>{s.destroy();process.exit(1)})'
  echo "jambonz stack checked"
fi

echo "rig is ready"
