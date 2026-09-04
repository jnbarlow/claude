#!/usr/bin/env bash
# UserPromptSubmit hook — evaluate if user prompt warrants LTM lookup and inject relevant context.
# Command-type hook that runs on every user prompt submission.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
HTTP_PORT_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm-mcp-port.txt"

# Resolve HTTP port from discovery file (written by MCP server on startup).
if [ ! -f "$HTTP_PORT_FILE" ]; then
  exit 0  # MCP server not running or hasn't started yet.
fi

HTTP_PORT=$(cat "$HTTP_PORT_FILE")
if [ -z "${HTTP_PORT:-}" ] || [ "$HTTP_PORT" -lt 1 ] 2>/dev/null; then
  exit 0  # Invalid port.
fi

# --- Step 1: Read JSON input from stdin ------------------------------------------

if ! read -r json_input; then
  exit 0  # No input, nothing to evaluate.
fi

# Extract prompt field using jq (handle missing gracefully).
prompt=$(echo "$json_input" | jq -r '.prompt // empty' 2>/dev/null) || true

# Skip if prompt is empty or too short (< 5 characters).
if [ -z "${prompt:-}" ] || [ ${#prompt} -lt 5 ]; then
  exit 0
fi

# --- Step 2: Extract keywords and query LTM ----------------------------------------
# FTS joins words with AND — long queries fail. Extract meaningful terms and query each separately.

# Common stop words to remove (English).
STOP_WORDS="a an the is are was were be been being have has had do does did will would shall should may might can could i me my we us our he him his she her they them their it its that that which who whom what where when how"

# Extract keywords: lowercase, >4 chars, remove stop words.
keywords=$(echo "$prompt" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]{4,}\b' | while read -r word; do
  if ! echo "$STOP_WORDS" | grep -qw "$word"; then
    echo "$word"
  fi
done | sort -u)

# Detect current project context for LTM scoring.
# Priority: CLAUDE_PROJECT_DIR > PWD > empty (no context boost).
CURRENT_CONTEXT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Query LTM for each keyword separately and combine results.
# Use deduplicate=true to filter out already-injected slugs (in-memory tracking in MCP server).
# Pass current_context for context-aware scoring (+50 boost for matching projects).
# Pass min_score=40 to filter out low-relevance noise (single tag hit without context match).
all_results=""
result_count=0

for kw in $keywords; do
  result=$(curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/api/tool" \
    -H "Content-Type: application/json" \
    -d "{\"tool\":\"ltm_recall_by_text\",\"params\":{\"query\":\"$kw\",\"deduplicate\":true,\"current_context\":\"$CURRENT_CONTEXT\",\"min_score\":40}}" \
    2>/dev/null) || continue

  if [ -n "${result:-}" ]; then
    formatted=$(echo "$result" | jq -r '.content[0].text // empty' 2>/dev/null) || true
    # Skip if no results or all were filtered (empty text after deduplication).
    if [ -n "${formatted:-}" ] && ! echo "$formatted" | grep -q "No matching memories"; then
      # Filter out superseded memories before injection.
      clean_formatted=$(echo "$formatted" | grep -v "\[superseded\]")
      if [ -n "${clean_formatted:-}" ]; then
        all_results="${all_results}${clean_formatted}
---SEPARATOR---
"
        result_count=$((result_count + 1))
      fi
    fi
  fi
done

if [ -z "${all_results:-}" ]; then
  exit 0  # All results filtered or no matches — noop.
fi

# --- Step 3: Deduplicate and format results ----------------------------------------

# Split on separator, deduplicate by slug, reformat.
formatted_result=$(echo "$all_results" | grep -v "^---SEPARATOR---$" | sed '/^$/d' | sort -u)

if [ -z "${formatted_result:-}" ]; then
  exit 0
fi

# Indent for readability — but limit to title/slug only (not full body).
indented=$(echo "$formatted_result" | grep -E "Slug:|• \[" | sed 's/^/   /' | head -50)

# --- Step 4: Output JSON with additionalContext -----------------------------------
# Use jq to safely escape the text content (handles quotes, newlines, special chars).

jq -n \
  --arg hookEventName "UserPromptSubmit" \
  --arg additionalContext "🧠 **Long-term memory auto-retrieved:**

${indented}" \
'{
  hookSpecificOutput: {
    hookEventName: $hookEventName,
    additionalContext: $additionalContext
  }
}'

exit 0