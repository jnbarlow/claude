#!/usr/bin/env bash
# Self-bootstrapping MCP server launcher.
# Runs npm install + TypeScript compile on first launch, then starts the Node server.
# This allows /reload-plugins to work immediately without requiring a session restart.

set -euo pipefail

PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-/tmp}"
MCP_SRC_DIR="${CLAUDE_PLUGIN_ROOT}/mcp-server"
MCP_DST_DIR="$PLUGIN_DATA/mcp-server"
BUILD_DIR="$MCP_DST_DIR/dist"

# Ensure destination directory exists before copying files.
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

# --- Step 3: Start Node server (handles schema migration inline) -----------------
exec node "$MCP_DST_DIR/dist/index.js"
