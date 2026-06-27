#!/usr/bin/env bash
# Bootstrap script for Claude Code long-term-memory plugin.
# Runs at SessionStart via hooks.json.
# Always exits 0 — never blocks Claude Code startup.
#
# Responsibilities:
#   1. Check if LTM_DB is configured → relay setup guidance to model context via stdout
#   2. Session preload: inject identity/preference memories into model context
#
# Note: npm install + TypeScript compile are handled by start-mcp.sh at MCP launch.
# Database schema migration is handled by the MCP server's bootstrap() in index.ts.

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

# --- Step 2: Session preload (identity, preferences, habits) --------------------
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
