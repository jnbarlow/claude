#!/usr/bin/env bash
# Bootstrap script for Claude Code long-term-memory plugin.
# Runs at SessionStart via hooks.json.
# Always exits 0 — never blocks Claude Code startup.
#
# Responsibilities:
#   1. Resolve connection string from configured provider (or env var fallback)
#   2. Check if LTM is reachable → relay setup guidance to model context via stdout
#   3. Session preload: inject identity/preference memories into model context

set -euo pipefail

SECRET_NAME="LTM-DB"                          # Fixed across all providers.
PROVIDER="${LTM_PROVIDER:-keychain}"           # Provider from config, defaults to keychain.
CONN=""

# --- Step 1: Resolve connection string from provider -------------------------

case "$PROVIDER" in
  aws)
    if command -v aws &>/dev/null; then
      CONN=$(aws secretsmanager get-secret-value --secret-id "$SECRET_NAME" \
        --query 'SecretString' --output text 2>/dev/null) || true
    else
      echo "[ltm-mcp] AWS CLI not found — cannot resolve secret from AWS Secrets Manager." >&2
    fi
    ;;

  1password)
    # Use op CLI (simpler than Connect Server for shell use, same auth backend).
    if command -v op &>/dev/null; then
      CONN=$(op read "op:///$SECRET_NAME/connection_string" 2>/dev/null) || true
    else
      echo "[ltm-mcp] op CLI not found — cannot resolve secret from 1Password." >&2
    fi
    ;;

  keychain|*)
    # macOS Keychain via security CLI or Linux Secret Service via secret-tool.
    if command -v security &>/dev/null; then
      CONN=$(security find-generic-password -s "ltm-mcp" -a "$SECRET_NAME" \
        -w 2>/dev/null) || true
    elif [ "${DBUS_SESSION_BUS_ADDRESS:-}" != "" ] && command -v secret-tool &>/dev/null; then
      CONN=$(secret-tool lookup service ltm-mcp account "$SECRET_NAME" 2>/dev/null) || true
    else
      echo "[ltm-mcp] No keychain tool available (macOS security or Linux secret-tool)." >&2
    fi
    ;;
esac

# Final fallback for local dev / headless environments where provider unavailable.
if [ -z "$CONN" ]; then
  CONN="${LTM_DB_URL:-}"
fi

# --- Step 2: Configuration check ---------------------------------------------

if [ -z "$CONN" ]; then
  echo "🧠 LTM: Long-term memory is not configured."
  echo "   To set it up:"
  echo '     1. Store your PostgreSQL connection string in a secrets provider (keychain, AWS, or 1Password) under the name LTM-DB'
  echo "      Or export LTM_DB_URL for local development"
  exit 0
fi

# --- Step 3: Session preload (identity, preferences, habits) ------------------

PRELOAD=$(psql "$CONN" -t -A --no-align \
  -c "SELECT slug || '|' || title || '|' || body FROM fn_session_preload(10);" 2>/dev/null) || true

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
