#!/usr/bin/env bash
# Arthas MCP Service manager
# start | stop | status | restart | doctor | demo-start | demo-stop
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SELF_DIR}/conf/arthas-mcp.env"
BOOT_JAR="${SELF_DIR}/arthas-home/arthas-boot.jar"
DEMO_JAR="${SELF_DIR}/arthas-home/math-game.jar"
DEMO_LOG="${SELF_DIR}/demo.log"
DEMO_PID_FILE="${SELF_DIR}/demo.pid"

# defaults (overridden by conf/arthas-mcp.env)
ARTHAS_MCP_PORT="8563"
ARTHAS_TELNET_PORT="3658"
ARTHAS_MCP_USERNAME="arthas"
ARTHAS_MCP_PASSWORD=""
ARTHAS_TARGET_PID=""
ARTHAS_TARGET_NAME=""

[ -f "$ENV_FILE" ] && . "$ENV_FILE"
[ -f "$BOOT_JAR" ] || { echo "ERROR: $BOOT_JAR not found (reinstall the package)"; exit 1; }

MCP_URL="http://127.0.0.1:${ARTHAS_MCP_PORT}${ARTHAS_MCP_ENDPOINT:-/mcp}"

say()  { echo -e "\033[36m[arthas-mcp]\033[0m $*"; }
err()  { echo -e "\033[31m[arthas-mcp]\033[0m $*" >&2; }

resolve_target_pid() {
  if [ -n "${ARTHAS_TARGET_PID:-}" ] && kill -0 "$ARTHAS_TARGET_PID" 2>/dev/null; then
    echo "$ARTHAS_TARGET_PID"; return 0
  fi
  if [ -n "${ARTHAS_TARGET_NAME:-}" ]; then
    local pid
    pid="$(pgrep -f "$ARTHAS_TARGET_NAME" | head -1 || true)"
    if [ -n "$pid" ]; then echo "$pid"; return 0; fi
  fi
  return 1
}

mcp_alive() {
  [ -n "$ARTHAS_MCP_PASSWORD" ] || return 1
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST "$MCP_URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer ${ARTHAS_MCP_PASSWORD}" \
    -d '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"healthcheck","version":"1"}}}' \
    2>/dev/null || echo 000)"
  [ "$code" = "200" ]
}

cmd_start() {
  if mcp_alive; then say "already running at $MCP_URL"; exit 0; fi
  local pid
  if ! pid="$(resolve_target_pid)"; then
    err "no target JVM configured/found."
    err "set ARTHAS_TARGET_PID or ARTHAS_TARGET_NAME in $ENV_FILE,"
    err "or start the bundled demo first: $0 demo-start"
    exit 1
  fi
  say "attaching Arthas to target JVM (pid=$pid), MCP port=${ARTHAS_MCP_PORT}"
  java -jar "$BOOT_JAR" \
    --arthas-home "${SELF_DIR}/arthas-home" \
    --http-port "${ARTHAS_MCP_PORT}" \
    --telnet-port "${ARTHAS_TELNET_PORT}" \
    --attach-only "$pid" </dev/null >/dev/null 2>&1 || {
      err "attach failed (is pid $pid a running Java process?)"; exit 1; }
  local i
  for i in $(seq 1 20); do
    mcp_alive && { say "MCP service is UP: $MCP_URL"; return 0; }
    sleep 1
  done
  err "attach succeeded but MCP endpoint health-check failed on $MCP_URL"
  err "check firewall/port availability, then retry with $0 doctor"
  exit 1
}

cmd_stop() {
  if ! mcp_alive; then say "not running"; exit 0; fi
  curl -s --max-time 10 -X POST "http://127.0.0.1:${ARTHAS_MCP_PORT}/api" \
    -u "${ARTHAS_MCP_USERNAME}:${ARTHAS_MCP_PASSWORD}" \
    -H 'Content-Type: application/json' \
    -d '{"action":"exec","command":"stop"}' >/dev/null 2>&1
  local i
  for i in $(seq 1 15); do
    mcp_alive || { say "stopped"; exit 0; }
    sleep 1
  done
  err "service still responding after stop attempt; check $MCP_URL"
  exit 1
}

cmd_status() {
  if mcp_alive; then
    say "RUNNING  endpoint=$MCP_URL  (Bearer token required)"
    exit 0
  else
    say "STOPPED"
    exit 3
  fi
}

cmd_doctor() {
  echo "== environment =="
  command -v java >/dev/null && java -version 2>&1 | head -1 || echo "java: NOT FOUND"
  echo "boot jar: $BOOT_JAR $( [ -f "$BOOT_JAR" ] && echo OK || echo MISSING )"
  echo "config  : $ENV_FILE $( [ -f "$ENV_FILE" ] && echo OK || echo MISSING )"
  echo "== listening port =="
  if command -v ss >/dev/null; then ss -ltn | grep -E ":${ARTHAS_MCP_PORT}\b" || echo "port ${ARTHAS_MCP_PORT}: not listening"; fi
  echo "== target =="
  local pid
  if pid="$(resolve_target_pid)"; then echo "target pid: $pid"; else echo "target: NOT FOUND"; fi
  echo "== MCP endpoint =="
  if mcp_alive; then echo "initialize: OK"; else echo "initialize: FAILED"; fi
}

cmd_demo_start() {
  if [ -f "$DEMO_PID_FILE" ] && kill -0 "$(cat "$DEMO_PID_FILE")" 2>/dev/null; then
    say "demo already running (pid $(cat "$DEMO_PID_FILE"))"; exit 0
  fi
  [ -f "$DEMO_JAR" ] || { err "demo jar missing: $DEMO_JAR"; exit 1; }
  nohup java -jar "$DEMO_JAR" > "$DEMO_LOG" 2>&1 &
  local pid=$!
  echo "$pid" > "$DEMO_PID_FILE"
  say "demo target started (math-game, pid=$pid, log: $DEMO_LOG)"
  # point the service at the demo process if nothing is configured
  if ! resolve_target_pid >/dev/null; then
    sed -i.bak "s|^ARTHAS_TARGET_PID=.*|ARTHAS_TARGET_PID=${pid}|" "$ENV_FILE"
    say "service target auto-set to demo pid ${pid}"
  fi
}

cmd_demo_stop() {
  if [ -f "$DEMO_PID_FILE" ]; then
    local pid; pid="$(cat "$DEMO_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; say "demo stopped (pid $pid)"; fi
    rm -f "$DEMO_PID_FILE"
  else
    say "no demo running"
  fi
}

case "${1:-}" in
  start)      cmd_start ;;
  stop)       cmd_stop ;;
  status)     cmd_status ;;
  restart)    cmd_stop; cmd_start ;;
  doctor)     cmd_doctor ;;
  demo-start) cmd_demo_start ;;
  demo-stop)  cmd_demo_stop ;;
  *) echo "Usage: $0 {start|stop|status|restart|doctor|demo-start|demo-stop}"; exit 1 ;;
esac
