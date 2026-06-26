#!/usr/bin/env bash
# Bootstrap script for Claude Code long-term-memory plugin.
# Runs at SessionStart via hooks.json.
# Always exits 0 — never blocks Claude Code startup.
#
# Responsibilities:
#   1. Check if LTM_DB is configured → relay setup guidance to model context via stdout
#   2. Install npm dependencies (once) into ${CLAUDE_PLUGIN_DATA}
#   3. Compile TypeScript MCP server
#   4. Session preload: inject identity/preference memories into model context

set -euo pipefail

CONN="${CLAUDE_PLUGIN_OPTION_LTM_DB:-}"

# --- Step 1: Configuration check -----------------------------------------------
if [ -z "$CONN" ]; then
  echo "🧠 LTM: Long-term memory is not configured."
  echo "   To set it up:"
  echo '     1. Provision a PostgreSQL database (local, Docker, or managed)'
  echo "   Or configure it via plugin settings: /plugin → long-term-memory"
  exit 0
fi

# --- Step 2: Install npm dependencies ------------------------------------------
PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-/tmp}"
MCP_SRC_DIR="${CLAUDE_PLUGIN_ROOT}/mcp-server"
BUILD_DIR="$PLUGIN_DATA/mcp-server/dist"

if [ ! -f "$PLUGIN_DATA/package-lock.json" ]; then
    cp "${MCP_SRC_DIR}/package.json" "$PLUGIN_DATA/" 2>/dev/null || true
    cd "$PLUGIN_DATA" && npm install >/dev/null 2>&1 || {
      echo "🧠 LTM: WARNING — npm install failed. MCP tools may not work."
      exit 0
    }
fi

# --- Step 3: Compile TypeScript -------------------------------------------------
if [ ! -d "$BUILD_DIR" ]; then
    cd "$PLUGIN_DATA" && npx tsc \
        --project "${MCP_SRC_DIR}/tsconfig.json" \
        --outDir "$BUILD_DIR" >/dev/null 2>&1 || {
      echo "🧠 LTM: WARNING — TypeScript compilation failed. MCP tools may not work."
      exit 0
    }
fi

# --- Step 4: Apply schema (idempotent DDL — safe on every run) -------------------
SCHEMA_FILE="${CLAUDE_PLUGIN_ROOT}/sql/schema.sql"
if [ -f "$SCHEMA_FILE" ]; then
    psql "$CONN" -f "$SCHEMA_FILE" >/dev/null 2>&1 || true
else
    echo "🧠 LTM: WARNING — schema.sql not found at $SCHEMA_FILE (stored functions may be missing)"
fi

# --- Step 5: Session preload (identity, preferences, habits) --------------------
PRELOAD=$(psql "$CONN" -t -A --no-align \
  -c "SELECT slug || '|' || title || '|' || body FROM fn_session_preload(5);" 2>/dev/null) || true

if [ -n "$PRELOAD" ]; then
  echo "🧠 LTM: Session preload — the following memories are loaded into context:"
  while IFS='|' read -r slug title body; do
    # Truncate long bodies for bootstrap output (keep first 120 chars).
    short_body=$(echo "$body" | head -c 120)
    echo "   • $title — $short_body [$slug]"
  done <<< "$PRELOAD"
else
  echo "🧠 LTM: No preload memories found (fresh database or no identity facts yet)."
fi

exit 0
