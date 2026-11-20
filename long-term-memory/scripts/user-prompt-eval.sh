#!/usr/bin/env bash
# UserPromptSubmit hook — evaluate if user prompt warrants LTM lookup and inject relevant context.
# Command-type hook that runs on every user prompt submission.

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
HTTP_PORT_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm-mcp-port.txt"

# Debug log for verifying the UserPromptSubmit hook fires and what it decides.
LOG_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm_user_prompt_eval_debug.log"
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

# Resolve shared-secret auth token (written by MCP server on startup). Required for /api/tool.
AUTH_TOKEN_FILE="${CLAUDE_PLUGIN_DATA:-/tmp}/ltm-mcp-auth.txt"
LTM_AUTH_TOKEN=""
if [ -f "$AUTH_TOKEN_FILE" ]; then
  LTM_AUTH_TOKEN=$(cat "$AUTH_TOKEN_FILE")
fi

# --- Step 1: Read JSON input from stdin ------------------------------------------

if ! read -r json_input; then
  exit 0  # No input, nothing to evaluate.
fi

# Extract prompt field using jq (handle missing gracefully).
prompt=$(echo "$json_input" | jq -r '.prompt // empty' 2>/dev/null) || true

# Skip if prompt is empty or too short (< 5 characters).
if [ -z "${prompt:-}" ] || [ ${#prompt} -lt 5 ]; then
  log_message "No relevant context — prompt too short/empty, nothing injected"
  exit 0
fi

# --- Step 2: Extract keywords and query LTM ----------------------------------------
# FTS joins words with AND — long queries fail. Extract meaningful terms and query each separately,
# then rank the combined results by relevance (see Step 3).

# Common stop words to remove (English).
STOP_WORDS="a an the is are was were be been being have has had do does did will would shall should may might can could i me our he him his she her they their it its that which who whom what when how"

# Extract keywords: lowercase, >4 chars, remove stop words.
keywords=$(echo "$prompt" | tr '[:upper:]' '[:lower:]' | grep -oE '\b[a-z]{4,}\b' | while read -r word; do
  if ! echo "$STOP_WORDS" | grep -qw "$word"; then
    echo "$word"
  fi
done | sort -u)

# Detect current project context for LTM scoring.
# Priority: CLAUDE_PROJECT_DIR > PWD > empty (no context boost).
CURRENT_CONTEXT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Query LTM per keyword and collect result blocks into an array.
# Use deduplicate=true to filter out already-injected slugs (in-memory tracking in MCP server).
# Pass current_context for context-aware scoring (+50 boost for matching projects).
# min_score=4: empirically derived floor, not a guess. Measured across 20 unrelated queries —
# junk scores max out at 3; genuine matches score 52+. A floor of ~4 cleanly separates them while
# keeping every real hit (relevant multi-word queries still surface via their strongest keyword).
results=()

for kw in $keywords; do
  result=$(curl -s -X POST "http://127.0.0.1:${HTTP_PORT}/api/tool" \
    -H "Content-Type: application/json" \
    -H "X-LTM-Token: ${LTM_AUTH_TOKEN}" \
    -d "{\"tool\":\"ltm_recall_by_text\",\"params\":{\"query\":\"$kw\",\"deduplicate\":true,\"current_context\":\"$CURRENT_CONTEXT\",\"min_score\":4}}" \
    2>/dev/null) || continue

  if [ -n "${result:-}" ]; then
    formatted=$(echo "$result" | jq -r '.content[0].text // empty' 2>/dev/null) || true
    # Skip if no results or all were filtered (empty text after deduplication).
    if [ -n "${formatted:-}" ] && ! echo "$formatted" | grep -q "No matching memories"; then
      # Filter out superseded memories before ranking/injection.
      clean_formatted=$(echo "$formatted" | grep -v "\[superseded\]")
      if [ -n "${clean_formatted:-}" ]; then
        results+=("$clean_formatted")
      fi
    fi
  fi
done

if [ ${#results[@]} -eq 0 ]; then
  log_message "No relevant context — no memories matched, nothing injected"
  exit 0
fi

# --- Step 3: Rank + dedup by relevance ---------------------------------------------
# Combine all result blocks. Each memory is a title line (• [status] Title) followed by a
# "Slug: <slug> | Score: N" line. Parse score+slug per unique slug, keep the best score seen,
# then emit slugs ordered by descending score and cap at top 5 memories. This replaces the old
# alphabetical sort -u (which ignored relevance) with proper relevance ranking.
ranked_slugs=$(printf '%s\n' "${results[@]}" | gawk '
  /^ *$/ { next }
  /Slug:/ && /Score:/ {
    if (match($0, /Slug: ([^ ]+) \| Score: (-?[0-9]+)/, m)) {
      slug=m[1]; score=m[2]+0
      if (!(slug in best) || score > best[slug]) { best[slug]=score; titles[slug]=title }
    }
  }
  /•/ { title=$0 }
  END { for (s in best) printf "%d\t%s\t%s\n", best[s], s, titles[s] }' | sort -t$'\t' -k1,1nr | head -5)

if [ -z "${ranked_slugs:-}" ]; then
  log_message "No relevant context — results filtered out, nothing injected"
  exit 0
fi

# Build ordered injected text: for each ranked slug, emit its title + slug/score line.
indented=""
while IFS=$'\t' read -r score slug title; do
  [ -z "${slug:-}" ] && continue
  indented="${indented}${title}
   Slug: ${slug} | Score: ${score}
"
done <<< "$ranked_slugs"

# How many distinct memories are being injected.
inject_count=$(printf '%s\n' "$ranked_slugs" | grep -c . || true)
log_message "Relevant memories found (${inject_count}) — injecting into context (top ${inject_count}/5 by relevance)"

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
