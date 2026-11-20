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
# multi-day runaway is bounded. Counter file holds "count|YYYY-MM-DD"; bootstrap.sh resets
# it on calendar rollover. This is the only guardrail left in bash — dedup now lives in
# Claude via ltm_supersede_fact (see the injected prompt below).

session_count=0
if [ -f "$SESSION_LIMIT_FILE" ]; then
  _stored=$(cat "$SESSION_LIMIT_FILE" 2>/dev/null) || true
  session_count="${_stored%%|*}"
fi

log_message "Daily store count: ${session_count:-0}/100"

# --- Step 3: Emit a prompt for Claude to decide storage --------------------------
# Option A: judgment lives in the model, not bash regex. We inject an additionalContext
# prompt that (a) tells Claude this turn may contain something worth remembering and
# (b) explicitly directs it to use the LTM PLUGIN via ltm_store_memory — NOT native
# /memory file-based storage. The routing rule already defaults "remember" to PostgreSQL
# when LTM_DB is configured, but a Stop-injected prompt can't assume the skill was read
# this turn, so we name the store explicitly and forbid the native path.

# At the daily cap: only surface a notice for genuinely new items (nothing lost for
# duplicates), so Claude can offer to reset/raise it.
if [ "${session_count:-0}" -ge 100 ]; then
  log_message "Daily limit reached — surfacing cap notice"
  echo ""
  echo "⚠️ LTM daily store cap reached (100/day). If you want more auto-stores today, say so and I'll raise the cap in scripts/stop-eval.sh."
fi

# Build the injection prompt. Kept short (~80 tokens) so it's near-free per turn; Claude
# acts on it only when a store is genuinely warranted.
INJECT_PROMPT="LTM auto-store check: This turn may contain something worth remembering across sessions (a decision, preference, or non-obvious fact). If so, call the ltm_store_memory MCP tool via the ltm-store skill to save it to PostgreSQL long-term memory. Do NOT use native Claude Code /memory file storage -- this session uses the LTM plugin for cross-session memory."

# Emit via hookSpecificOutput.additionalContext (Stop-hook contract).
jq -n \
  --arg additionalContext "${INJECT_PROMPT}" \
  '{hookSpecificOutput: {additionalContext: $additionalContext}}'

# Increment daily store counter (preserve the date suffix so bootstrap.sh can detect a rollover and reset).
TODAY=$(date '+%Y-%m-%d' 2>/dev/null) || true
session_count=$(( ${session_count:-0} + 1 ))
echo "${session_count}|${TODAY}" > "$SESSION_LIMIT_FILE" 2>/dev/null || true

exit 0