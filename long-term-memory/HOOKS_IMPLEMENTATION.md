# LTM Proactive Hooks Implementation

## Overview

This implementation adds two new hooks to the Long-Term Memory (LTM) plugin that automatically evaluate user prompts and conversation context for memory-worthy information. The hooks make memory management more proactive without being intrusive.

## Components Implemented

### 1. Hook Scripts

#### `scripts/user-prompt-eval.sh`
- **Hook Type**: UserPromptSubmit
- **Purpose**: Evaluate if a user prompt warrants LTM lookup and inject relevant context
- **Behavior**:
  - Extracts keywords from user prompts using PostgreSQL's FTS capabilities
  - Queries LTM via MCP server with OR mode (default) for broader recall
  - Injects full memory content into Claude's context when relevant memories are found
  - Skips short prompts (< 5 characters) and empty inputs

#### `scripts/stop-eval.sh`
- **Hook Type**: Stop
- **Purpose**: Evaluate if conversation information is worth storing in LTM
- **Behavior**:
  - Detects decision patterns ("we should", "let's use", etc.)
  - Queries LTM for existing memories on that topic (duplicate check)
  - Auto-stores memories with guards:
    - Decision pattern required
    - Session limit (max 5 auto-stores per session)
    - Minimum content length checks (20-500 chars)
  - Outputs confirmation to stderr

#### `scripts/mcp-invoke.js`
- **Purpose**: Node.js wrapper for invoking MCP tools from bash scripts
- **Usage**: Enables command-type hooks to communicate with the MCP server via stdin/stdout JSON-RPC
- **Modes**: 
  - CLI arguments: `node mcp-invoke.js <tool_name> [--key value ...]`
  - Pipe mode: `echo '{"tool":"...","params":{...}}' | node mcp-invoke.js`

### 2. Schema Migration (v2)

#### `sql/schema_v2.sql`
- **Purpose**: Migration file that modifies `fn_recall_by_text` to support OR/AND modes
- **Changes**:
  - Added `p_mode` parameter (default 'OR') to `fn_recall_by_text`
  - Implemented mode-aware tsquery construction:
    - OR mode: splits query into words and joins with `|` for broader recall
    - AND mode: uses `plainto_tsquery` for strict matching between all terms
  - Includes UPDATE statement to bump schema_version

#### `sql/schema.sql`
- **Updates**:
  - Changed INSERT statement from `VALUES (1)` to `VALUES (2)` to reflect v2 state
  - Added `p_mode` parameter to `fn_recall_by_text` function signature
  - Added mode-aware tsquery construction logic matching migration file

### 3. Hooks Configuration

#### `hooks/hooks.json`
- **Added Events**:
  - `UserPromptSubmit`: Fires on every user prompt submission (30-second timeout)
  - `Stop`: Fires on every assistant response completion

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Hook type | Command-type (bash scripts) | Avoid token overhead, deterministic execution |
| MCP invocation | Node.js wrapper script | Reuse existing infrastructure, clean API |
| Search approach | Pure FTS with OR/AND modes | Leverage PostgreSQL's built-in capabilities |
| UserPromptSubmit | Inject context via `additionalContext` | Only reliable way on this event type |
| Stop hook | Auto-store memories with guards | Proactive without being intrusive |

## Key Features

### UserPromptSubmit Hook
- **Intelligent keyword extraction**: Uses PostgreSQL's FTS for stop word removal and stemming
- **OR mode by default**: Broader recall to catch more relevant memories
- **No truncation**: Include full memory content when recalled — partial memories could be misleading
- **Graceful degradation**: Exits silently if MCP server unavailable

### Stop Hook
- **Decision pattern detection**: Only triggers on clear decision signals
- **Duplicate prevention**: Queries LTM before storing to avoid redundant memories
- **Session limits**: Max 5 auto-stores per session prevents over-storing
- **Content validation**: Skips very short or very long summaries

## Testing

All scripts have been verified for syntax correctness:
```bash
bash -n user-prompt-eval.sh    # ✓ syntax OK
bash -n stop-eval.sh           # ✓ syntax OK
```

## Migration Path

The MCP server will automatically apply schema_v2.sql on next startup if the current schema_version is 1. The migration is idempotent and safe to re-run.

## Files Created/Modified

| File | Status | Description |
|------|--------|-------------|
| `scripts/user-prompt-eval.sh` | CREATED | UserPromptSubmit hook script |
| `scripts/stop-eval.sh` | CREATED | Stop hook script |
| `scripts/mcp-invoke.js` | CREATED | MCP invocation helper |
| `sql/schema_v2.sql` | CREATED | Schema migration v2 |
| `sql/schema.sql` | MODIFIED | Updated to reflect v2 state |
| `hooks/hooks.json` | MODIFIED | Added UserPromptSubmit and Stop entries |

## Next Steps

1. Test hooks in a live Claude Code session
2. Monitor debug logs for hook behavior
3. Adjust decision patterns and thresholds based on usage
4. Consider adding more sophisticated pattern detection if needed