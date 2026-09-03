#!/usr/bin/env bash
# Stop hook — evaluate if conversation information is worth storing in LTM.
# Command-type hook that fires on every assistant response completion.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
HTTP_PORT_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm-mcp-port.txt"
SESSION_LIMIT_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm_session_store_count"

# Debug log file for verifying hook behavior.
LOG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm_stop_hook_debug.log"

# Log a message with timestamp to the debug log file.
log_message() {
  local msg="$1"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE" 2>/dev/null || true
}

# Resolve HTTP port from discovery file (written by MCP server on startup).
if [ ! -f "$HTTP_PORT_FILE" ]; then
  exit 0  # MCP server not running or hasn't started yet.
fi

HTTP_PORT=$(cat "$HTTP_PORT_FILE")
if [ -z "${HTTP_PORT:-}" ] || [ "$HTTP_PORT" -lt 1 ] 2>/dev/null; then
  exit 0  # Invalid port.
fi

# --- Step 1: Read JSON input from stdin --------------------------------------------

if ! read -r json_input; then
  exit 0  # No input, nothing to evaluate.
fi

# Extract stop_hook_active field (boolean indicating if hook already fired).
stop_hook_active=$(echo "$json_input" | jq -r '.stop_hook_active // false' 2>/dev/null) || true

if [ "$stop_hook_active" = "true" ]; then
  exit 0  # Already handled this turn.
fi

# Extract last_assistant_message field.
last_message=$(echo "$json_input" | jq -r '.last_assistant_message // empty' 2>/dev/null) || true

# Skip if message is empty or too short (< 50 characters).
if [ -z "${last_message:-}" ] || [ ${#last_message} -lt 50 ]; then
  exit 0
fi

# --- Step 2: Check for decision patterns using grep/regex ---------------------------
# Patterns that indicate a meaningful decision was made.

decision_detected=false
decision_text=""

# Signal 1: Explicit decision language (high confidence)
if echo "$last_message" | grep -qiE "we should|let's use|i decided|we'll go with|we need to|we've got to|it makes sense to|the best approach is|we ought to"; then
  decision_detected=true
  log_message "Signal 1 (explicit decision) detected"
fi

# Signal 2: Resolution/conclusion markers (medium confidence)
if echo "$last_message" | grep -qiE "the plan is|i'm going to|so the approach is|in summary, we|after thinking about it|given that|considering this|bottom line is|at the end of the day|to sum up"; then
  decision_detected=true
  log_message "Signal 2 (resolution marker) detected"
fi

# Signal 3: Contrast/choice language (medium confidence)
if echo "$last_message" | grep -qiE "instead of|rather than using|vs\.? i prefer|choose.*over|compared to|as opposed to|over using|better than|more than"; then
  decision_detected=true
  log_message "Signal 3 (contrast/choice) detected"
fi

# Signal 4: Insight/recognition markers (high confidence)
if echo "$last_message" | grep -qiE "i realized|turns out|key insight is|we should never|always remember to|now i see|it clicked that|what happened was|i figured out|the problem was|i noticed that|the issue is|here's the thing|the catch is"; then
  decision_detected=true
  log_message "Signal 4 (insight/recognition) detected"
fi

if [ "$decision_detected" = "false" ]; then
  exit 0  # No decision detected.
fi

# Extract the sentence containing the decision (first sentence with a decision keyword).
decision_text=$(echo "$last_message" | grep -oiE "(we should|let's use|i decided|we'll go with|the plan is|so the approach is|instead of|rather than|i realized|turns out).*\." | head -1) || true

if [ -z "${decision_text:-}" ]; then
  # Fallback: take first sentence.
  decision_text=$(echo "$last_message" | sed -n 's/^\([^\.]*\)\..*/\1./p' | head -1) || true
fi

if [ -z "${decision_text:-}" ]; then
  log_message "Could not extract decision text — exiting"
  exit 0
fi

log_message "Decision detected: ${decision_text:0:100}..."

# --- Step 3: Check session limit (max 5 auto-stores per session) -------------------
session_count=0
if [ -f "$SESSION_LIMIT_FILE" ]; then
  session_count=$(cat "$SESSION_LIMIT_FILE") || true
fi

log_message "Session store count: ${session_count:-0}/5"

if [ "${session_count:-0}" -ge 5 ]; then
  log_message "Session limit reached — skipping auto-store"
  exit 0
fi

# --- Step 4: Extract topic and query LTM for duplicates ----------------------------
# Use first meaningful phrase from decision text as topic.

topic=$(echo "$decision_text" | sed "s/.*\(we should\|let's use\|I decided\|we'll go with\|going to use\|picking\)[[:space:]]*//" | cut -d' ' -f1-5)
log_message "Extracted topic: ${topic}"

# Query LTM for existing memories on that topic via HTTP.
existing=$(curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/api/tool" \
  -H "Content-Type: application/json" \
  -d "{\"tool\":\"ltm_recall_by_text\",\"params\":{\"query\":\"${topic}\"}}" \
  2>/dev/null) || true

if [ -n "${existing:-}" ]; then
  existing_text=$(echo "$existing" | jq -r '.content[0].text // empty' 2>/dev/null) || true
  if [ -n "${existing_text:-}" ] && ! echo "$existing_text" | grep -q "No matching memories"; then
    # Similar memory exists — skip auto-store.
    log_message "Duplicate detected — skipping auto-store (similar memory exists)"
    exit 0
  fi
fi

log_message "No duplicate found — proceeding to store"

# --- Step 5: Auto-store the memory -------------------------------------------------
# Extract a concise summary (first sentence or key points).

summary=$(echo "$decision_text" | cut -d'.' -f1)

if [ ${#summary} -lt 20 ] || [ ${#summary} -gt 500 ]; then
  log_message "Summary too short/long (${#summary} chars) — skipping"
  exit 0
fi

# Generate slug from topic (lowercase, replace spaces with hyphens).
slug=$(echo "$topic" | tr 'A-Z' 'a-z' | sed 's/ /-/g')

# Extract tags from decision text (first 3 meaningful words, >4 chars).
# Use jq to build JSON array safely.
tags_json=$(echo "$decision_text" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]{4,}\b' | sort -u | head -3 | jq -R . | jq -s '.')

log_message "Storing memory: slug=decision-${slug}, topic=${topic}"

# Store memory via HTTP — follow same convention as other storage (dynamic tags).
store_result=$(curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/api/tool" \
  -H "Content-Type: application/json" \
  -d "{\"tool\":\"ltm_store_memory\",\"params\":{\"slug\":\"decision-${slug}\",\"title\":\"$(echo "$topic" | head -c 50)\",\"body\":\"${summary}\",\"category\":\"decision\",\"context\":\"auto-stored from Stop hook\",\"tags\":${tags_json}}}" \
  2>/dev/null) || true

if [ -n "${store_result:-}" ] && echo "$store_result" | grep -q "Stored"; then
  log_message "Successfully stored memory (slug=decision-${slug})"
else
  log_message "Failed to store memory — curl result: ${store_result:-empty}"
fi

# Increment session counter.
session_count=$(( ${session_count:-0} + 1 ))
echo "$session_count" > "$SESSION_LIMIT_FILE"

exit 0