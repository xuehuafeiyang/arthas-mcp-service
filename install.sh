#!/usr/bin/env bash
# Arthas MCP Service - one-click installer
# Bundles official Arthas 4.3.5 (with built-in MCP Server) as a local service
# that any MCP-capable LLM client can connect to.
#
# Usage:
#   ./install.sh [options]
# Options:
#   --port <port>        MCP/HTTP port (default 8563, configurable)
#   --telnet-port <port> telnet console port (default 3658)
#   --password <secret>  Bearer token / password (default: random 24-hex)
#   --username <name>    auth username (default: arthas)
#   --dir <path>         install directory (default /opt/arthas-mcp, fallback
#                        to $HOME/arthas-mcp when not writable)
#   --pid <pid>          target Java process id to attach
#   --name <pattern>     target Java process name (pgrep -f) when --pid absent
#   --protocol <mode>    STREAMABLE (default) or STATELESS
#   --no-systemd         skip systemd unit installation even if available
#   --demo               after install, start bundled math-game.jar and attach
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="4.3.5"

PORT="8563"
TELNET_PORT="3658"
PASSWORD=""
USERNAME="arthas"
INSTALL_DIR=""
TARGET_PID=""
TARGET_NAME=""
PROTOCOL="STREAMABLE"
NO_SYSTEMD="0"
START_DEMO="0"

log()  { echo -e "\033[32m[install]\033[0m $*"; }
warn() { echo -e "\033[33m[install]\033[0m $*" >&2; }
die()  { echo -e "\033[31m[install] ERROR:\033[0m $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)         PORT="$2"; shift 2 ;;
    --telnet-port)  TELNET_PORT="$2"; shift 2 ;;
    --password)     PASSWORD="$2"; shift 2 ;;
    --username)     USERNAME="$2"; shift 2 ;;
    --dir)          INSTALL_DIR="$2"; shift 2 ;;
    --pid)          TARGET_PID="$2"; shift 2 ;;
    --name)         TARGET_NAME="$2"; shift 2 ;;
    --protocol)     PROTOCOL="$2"; shift 2 ;;
    --no-systemd)   NO_SYSTEMD="1"; shift ;;
    --demo)         START_DEMO="1"; shift ;;
    -h|--help)      sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ -x "$(command -v java)" ] || die "java not found in PATH. Install JDK/JRE 8+ first."
JAVA_MAJOR=$(java -version 2>&1 | head -1 | sed -E 's/.*"([0-9]+)[."].*/\1/')
[ "$JAVA_MAJOR" -ge 8 ] || die "Arthas ${VERSION} requires JDK 8+, found: ${JAVA_MAJOR}"

case "$PROTOCOL" in
  STREAMABLE|STATELESS) ;;
  *) die "--protocol must be STREAMABLE or STATELESS" ;;
esac

if [ -z "$INSTALL_DIR" ]; then
  INSTALL_DIR="/opt/arthas-mcp"
  if ! mkdir -p "$INSTALL_DIR" 2>/dev/null; then
    INSTALL_DIR="$HOME/arthas-mcp"
    warn "/opt not writable, falling back to $INSTALL_DIR"
  fi
fi
mkdir -p "$INSTALL_DIR"

if [ -z "$PASSWORD" ]; then
  PASSWORD="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  log "generated random password/token: $PASSWORD"
fi

log "installing Arthas MCP Service ${VERSION} into $INSTALL_DIR"
rm -rf "$INSTALL_DIR/arthas-home" "$INSTALL_DIR/conf"
mkdir -p "$INSTALL_DIR/conf"
cp -r "$SCRIPT_DIR/dist" "$INSTALL_DIR/arthas-home"

# render arthas.properties from template
PROPS="$INSTALL_DIR/arthas-home/arthas.properties"
sed -e "s|__PORT__|${PORT}|g" \
    -e "s|__TELNET_PORT__|${TELNET_PORT}|g" \
    -e "s|__USERNAME__|${USERNAME}|g" \
    -e "s|__PASSWORD__|${PASSWORD}|g" \
    -e "s|__MCP_ENDPOINT__|/mcp|g" \
    -e "s|__MCP_PROTOCOL__|${PROTOCOL}|g" \
    "$SCRIPT_DIR/dist/arthas.properties" > "$PROPS"
chmod 600 "$PROPS"

# service env file consumed by arthas-mcp.sh
cat > "$INSTALL_DIR/conf/arthas-mcp.env" <<EOF
# Arthas MCP Service runtime configuration (edit and restart the service)
ARTHAS_MCP_PORT=${PORT}
ARTHAS_TELNET_PORT=${TELNET_PORT}
ARTHAS_MCP_USERNAME=${USERNAME}
ARTHAS_MCP_PASSWORD=${PASSWORD}
ARTHAS_MCP_PROTOCOL=${PROTOCOL}
# Target JVM to attach to: pid takes precedence over name
ARTHAS_TARGET_PID=${TARGET_PID}
ARTHAS_TARGET_NAME=${TARGET_NAME}
EOF
chmod 600 "$INSTALL_DIR/conf/arthas-mcp.env"

cp "$SCRIPT_DIR/arthas-mcp.sh" "$INSTALL_DIR/arthas-mcp.sh"
chmod +x "$INSTALL_DIR/arthas-mcp.sh"
[ -f "$SCRIPT_DIR/README.md" ] && cp "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md"

# optional systemd unit
SYSTEMD_UNIT=""
if [ "$NO_SYSTEMD" = "0" ] && command -v systemctl >/dev/null 2>&1 \
   && [ -d /etc/systemd/system ] && mkdir -p /etc/systemd/system 2>/dev/null; then
  SYSTEMD_UNIT="/etc/systemd/system/arthas-mcp.service"
  cat > "$SYSTEMD_UNIT" <<EOF
[Unit]
Description=Arthas MCP Server (${VERSION}) - LLM diagnosable Java service
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
EnvironmentFile=${INSTALL_DIR}/conf/arthas-mcp.env
ExecStart=${INSTALL_DIR}/arthas-mcp.sh start
ExecStop=${INSTALL_DIR}/arthas-mcp.sh stop
ExecReload=${INSTALL_DIR}/arthas-mcp.sh restart
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload 2>/dev/null || true
  log "systemd unit installed: $SYSTEMD_UNIT"
else
  log "systemd not available/writable - use $INSTALL_DIR/arthas-mcp.sh directly"
fi

if [ "$START_DEMO" = "1" ]; then
  log "starting bundled demo target (math-game.jar)"
  "$INSTALL_DIR/arthas-mcp.sh" demo-start
fi

cat <<EOF

============================================================
 Arthas MCP Service ${VERSION} installed
------------------------------------------------------------
 Install dir   : ${INSTALL_DIR}
 MCP endpoint  : http://127.0.0.1:${PORT}/mcp
 Protocol      : ${PROTOCOL} (Streamable HTTP)
 Bearer token  : ${PASSWORD}
 Management    : ${INSTALL_DIR}/arthas-mcp.sh {start|stop|status|restart|doctor}
 systemd       : ${SYSTEMD_UNIT:-not installed}
------------------------------------------------------------
 Next:
   1) start the service and attach to a target JVM:
        ${INSTALL_DIR}/arthas-mcp.sh start
      (no target configured yet? run: ${INSTALL_DIR}/arthas-mcp.sh demo-start)
   2) verify:
        curl -s http://127.0.0.1:${PORT}/mcp -X POST \\
          -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \\
          -H 'Authorization: Bearer ${PASSWORD}' \\
          -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}'
   3) add to your LLM / MCP client (streamableHttp):
        {
          "mcpServers": {
            "arthas-mcp": {
              "type": "streamableHttp",
              "url": "http://127.0.0.1:${PORT}/mcp",
              "headers": { "Authorization": "Bearer ${PASSWORD}" }
            }
          }
        }
============================================================
EOF
