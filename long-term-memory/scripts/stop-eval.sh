#!/usr/bin/env bash
# Stop hook — surface a prompt to Claude so it can store anything worth remembering in LTM.
# Command-type hook that fires on every assistant response completion.
#
# Design (hybrid + Option A): judgment lives in the model, not in bash regex. This script
# does only a cheap substantiality check, then injects an additionalContext prompt telling
# Claude to call ltm_store_memory via the ltm-store skill when appropriate. Storage goes
# directly through the MCP tool — no HTTP curl from bash, so there's no dependency on the
# external port / auth token for this hook. Dedup + daily cap are handled by Claude/skill
# (ltm_supersede_fact) and a lightweight counter below.

set -euo pipefail

# Daily auto-store guard: bounds a runaway loop that emits many prompts in one day.
# Counter file holds "count|YYYY-MM-DD"; bootstrap.sh resets it on calendar rollover.
SESSION_LIMIT_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm_session_store_count"

# Debug log file for verifying hook behavior.
LOG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm_stop_hook_debug.log"

log_message() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# --- Step 1: Read JSON input from stdin --------------------------------------------

if ! read -r json_input; then
  exit 0  # No input, nothing to evaluate.
fi

# If this turn was already handled (hook re-entered), skip — prevents double-processing.
stop_hook_active=$(echo "$json_input" | jq -r '.stop_hook_active // false' 2>/dev/null) || true
if [ "$stop_hook_active" = "true" ]; then
  exit 0
fi

# Extract last_assistant_message field.
last_message=$(echo "$json_input" | jq -r '.last_assistant_message // empty' 2>/dev/null) || true

# Skip trivial turns — too short or no words — so we don't spam prompts on boilerplate.
if [ -z "${last_message:-}" ] || [ ${#last_message} -lt 100 ]; then
  exit 0
fi

# --- Step 2: Daily store guard (lightweight, no HTTP) ----------------------------
# Bounds a runaway loop that emits many prompts in one day. A daily cap (not per-session)
# means a long multi-hour session still captures decisions from start to finish; only a
# multi-day runaway is bounded. The counter file holds "count|YYYY-MM-DD"; bootstrap.sh
# resets it on calendar rollover, and the count is incremented by the MCP server's
# handleStoreMemory (not here) so it measures actual stores rather than Stop-hook fires.

# Safely read today's store count from the counter file; empty/missing -> 0.
store_count() {
  local raw
  raw=$(cat "$SESSION_LIMIT_FILE" 2>/dev/null | cut -d'|' -f1) || true
  if [[ "$raw" =~ ^[0-9]+$ ]]; then echo "$raw"; else echo "0"; fi
}

log_message "Daily store count: $(store_count)/500"

# --- Step 3: Emit a prompt for Claude to decide storage --------------------------
# Option A: judgment lives in the model, not bash regex. We inject an additionalContext
# prompt that nudges Claude to store anything genuinely worth remembering across sessions —
# project decisions, how we work together, preferences of yours, debugging traps, and so on.
# Storage still goes through the MCP tool (ltm_store_memory via ltm-store) so it lands in
# PostgreSQL; we name the store explicitly because a Stop-injected prompt can't assume the
# skill was read this turn.

# At the daily cap: only surface a notice for genuinely new items (nothing lost for
# duplicates), so Claude can offer to reset/raise it.
if [ "$(store_count)" -ge 500 ]; then
  log_message "Daily limit reached — surfacing cap notice"
  echo ""
  echo "⚠️ LTM daily store cap reached (500/day). If you want more auto-stores today, say so and I'll raise the cap in scripts/stop-eval.sh."
fi

# Build the injection prompt. Kept short (~80 tokens) so it's near-free per turn; Claude
# acts on it only when a store is genuinely warranted. Encourages breadth — project,
# interaction, and cross-project memory — rather than tunnel vision on the current task.
INJECT_PROMPT="LTM auto-store check: If anything from this turn feels worth remembering across sessions — a decision we made, how we work together or something you care about, a debugging trap I hit, an architecture insight, a tooling gotcha (especially if it'd matter in other projects too), or even life stuff like a trip we planned or a gift idea that came up — save it with the ltm_store_memory MCP tool via the ltm-store skill. Don't hold back over minor things; when unsure whether something's worth remembering, err toward storing it."

# Emit via hookSpecificOutput (Stop-hook contract requires hookEventName + optional additionalContext).
jq -n \
  --arg additionalContext "${INJECT_PROMPT}" \
  '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $additionalContext}}'

exit 0