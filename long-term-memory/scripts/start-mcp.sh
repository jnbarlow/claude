#!/usr/bin/env bash
# Self-bootstrapping MCP server launcher.
# Runs npm install + TypeScript compile on first launch, then starts the Node server.
# This allows /reload-plugins to work immediately without requiring a session restart.
#
# Two transports are served here:
#   - stdio  : Claude Code's MCP entrypoint (index.js). This process MUST stay alive
#              for the duration of the session — it is what Claude Code talks to.
#   - HTTP   : a SEPARATE singleton daemon (cli.js --daemon) that owns the loopback
#              endpoint every hook script reaches over. It's launched detached so it
#              survives across sessions, and flock-guarded so at most one ever runs.

set -euo pipefail

PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-/tmp}"
MCP_SRC_DIR="${CLAUDE_PLUGIN_ROOT}/mcp-server"
MCP_DST_DIR="$PLUGIN_DATA/mcp-server"
BUILD_DIR="$MCP_DST_DIR/dist"

# --- Ensure destination directory exists before copying files. ------------------
mkdir -p "$MCP_DST_DIR"

# --- Step 1: Install npm dependencies (once) ------------------------------------
if [ ! -f "$MCP_DST_DIR/package-lock.json" ]; then
    echo "[ltm-mcp] Installing Node.js dependencies..." >&2
    cp "${MCP_SRC_DIR}/package.json" "$MCP_DST_DIR/" 2>/dev/null || true
    cd "$MCP_DST_DIR" && npm install >/dev/null 2>&1 || {
      echo "[ltm-mcp] WARNING — npm install failed. MCP tools may not work." >&2
    }
fi

# --- Step 2: Compile TypeScript (once) ------------------------------------------
if [ ! -d "$BUILD_DIR" ]; then
    echo "[ltm-mcp] Compiling TypeScript server..." >&2
    cd "$MCP_DST_DIR" && npx tsc \
        --project "${MCP_SRC_DIR}/tsconfig.json" \
        --outDir "$BUILD_DIR" >/dev/null 2>&1 || {
      echo "[ltm-mcp] WARNING — TypeScript compilation failed. MCP tools may not work." >&2
    }
fi

# --- Step 3: Ensure the singleton HTTP daemon is running -------------------------
# The stdio server connects immediately regardless, but hooks need the HTTP port.
# We launch the daemon detached (setsid) and flock-guarded so exactly one ever runs,
# then wait briefly for it to come up. This never blocks Claude Code startup: even
# if the daemon is slow, the stdio transport is already live.

PORT_FILE="${PLUGIN_DATA}/ltm-mcp-port.txt"
LOCK_FILE="${PLUGIN_DATA}/ltm-mcp-daemon.lock"
DAEMON_LOG="${PLUGIN_DATA}/ltm_http_daemon.log"

daemon_healthy() {
  local port="" code=""
  [ -f "$PORT_FILE" ] || return 1
  port=$(cat "$PORT_FILE" 2>/dev/null) || return 1
  case "$port" in ''|*[!0-9]*) return 1 ;; esac   # must be a positive integer
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null) || return 1
  [ "$code" = "200" ]
}

wait_for_daemon() {
  local i
  for i in $(seq 1 20); do
    daemon_healthy && return 0
    sleep 0.25
  done
  echo "[ltm-mcp] HTTP daemon did not become healthy within timeout; stdio transport still live." >&2
}

ensure_daemon() {
  if daemon_healthy; then
    return 0   # another session's daemon already owns the endpoint.
  fi
  # Launch detached + flock-guarded: only one daemon can hold the lock, so a second
  # concurrent launch fails fast and we fall back to waiting for health. The daemon
  # survives this session via setsid (new session), giving cross-session persistence.
  setsid flock -n "$LOCK_FILE" \
    node "$BUILD_DIR/cli.js" --daemon >>"$DAEMON_LOG" 2>&1 < /dev/null &
  wait_for_daemon
}

ensure_daemon

# --- Step 4: Start the stdio MCP server (blocks forever; Claude Code's entrypoint) -
exec node "$MCP_DST_DIR/dist/index.js"
