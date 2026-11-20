#!/usr/bin/env bash
# Uninstall Arthas MCP Service (does NOT touch the target Java application)
set -uo pipefail
INSTALL_DIR="${1:-/opt/arthas-mcp}"

if command -v systemctl >/dev/null 2>&1; then
  systemctl stop arthas-mcp 2>/dev/null || true
  systemctl disable arthas-mcp 2>/dev/null || true
  rm -f /etc/systemd/system/arthas-mcp.service
  systemctl daemon-reload 2>/dev/null || true
fi
[ -x "$INSTALL_DIR/arthas-mcp.sh" ] && "$INSTALL_DIR/arthas-mcp.sh" stop >/dev/null 2>&1

rm -rf "$INSTALL_DIR"
echo "[uninstall] removed $INSTALL_DIR (target JVM untouched)"
