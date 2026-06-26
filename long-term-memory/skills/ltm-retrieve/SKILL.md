---
name: ltm-retrieve
description: |
  Query long-term memory using the bundled MCP server. Recall facts, decisions, preferences relevant to the current task.
allowed-tools: Read, Glob
version: "1.0.0"
tags: [memory, postgresql, recall]
---

# Long-Term Memory Retrieval

## ⚡ First Turn Behavior (Always Execute)

On your very first response in any new session or after /clear:

1. **Check** if you received hook output beginning with `🧠 LTM:` — this comes from the bootstrap script running at SessionStart; its stdout lands silently in your context, not on screen
2. **If yes → surface that message to the user IMMEDIATELY before doing anything else.** Do NOT wait for a skill invocation or for the user to ask about memory configuration

This is how setup guidance reaches users — without this relay they'd never know LTM isn't configured.

## 🔄 Session Preload (Automatic)

At session start, bootstrap.sh calls `fn_session_preload(5)` and injects results into model context via stdout. This pre-loads up to 5 current memories weighted by category priority:

| Category | Priority Weight | Loaded First? |
|---|---|---|
| `user-identity` | 100 | Yes — name, role, expertise |
| `workflow-preferences` | 80 | Early — how user works |
| `coding-style` | 75 | Early — conventions & taste |
| `user-preferences` | 70 | Mid — general preferences |
| Any other category | 10 (default) | Only if < 5 higher-priority facts exist |

A recency bonus (+20) is also applied to memories verified within the last 90 days. The preload output appears in hook context as `🧠 LTM: Session preload — ...`. Surface it on first turn per the rules above.

## Routing Rule (Decision 3.5)
When `LTM_DB` is configured, all "remember" commands default to PostgreSQL LTM via the ltm-store skill. To explicitly use native Claude Code file-based memory instead, invoke `/memory [text]`. The presence of `$LTM_DB` config is the signal — no special phrases needed. When absent, fall back to native Claude Code memory behavior unchanged.

## When to Recall

Query memory proactively at these trigger points. Use judgment — do NOT dump all memories on session start. Recall is reactive and context-triggered like human memory.

### 1. Plan Mode Entry or Task Planning
Before building a plan for any task, check if there are relevant prior decisions about this domain (architecture choices, coding preferences, project conventions). Extract 2–3 keywords from the current task to search by topic.

**Example:** User says "plan how we should handle auth" → recall with tag pattern `auth` or text query `authentication strategy`.

### 2. Corrections Received from User
When corrected ("actually we use X not Y"), look up what was previously stored about this topic BEFORE deciding whether a supersession is needed via the ltm-store skill. This prevents storing contradictory facts without knowing which one to keep as current.

**Example:** User says "we're using JWT, not sessions" → first recall by topic `authentication` to see what's already stored before calling `ltm_supersede_fact`.

### 3. Decision Points During Conversation
At any decision point in the conversation, check for prior decisions on the same or related topics to avoid contradicting established choices. This is especially important when choosing between technical approaches, naming conventions, or architectural patterns.

**Example:** About to recommend a database migration strategy → recall by topic `%database%`.

### 4. Unfamiliar Territory
When encountering an unfamiliar topic in this project, do a broad text search to see if context exists from previous sessions. Use full-text search for the widest net when you have no idea what tags might apply.

**Example:** User references "the Geoswitch project" and you've never heard of it → recall by text `Geoswitch`.

### 5. Forming or Revising Opinions (Organic Memory)
When you're about to store an observation, opinion, or judgment — especially one that builds on prior understanding — check what's already stored first. This prevents duplicate memories and helps you decide whether to supersede an existing fact with a refined view rather than adding a new one alongside it.

**Example:** You notice the user prefers minimal abstractions → recall by topic `%user-understanding%` or text `abstraction preference`. If there's an earlier memory about their taste that was incomplete, supersede it instead of creating a parallel fact.

### 6. End-of-Conversation Reflection
Before a session wraps up, take a moment to scan for patterns or observations worth storing — things you've noticed but haven't yet recorded. This is the equivalent of "after meeting someone and thinking about what they were like on the way home." Store anything that deepens your understanding of the user, their work, or ongoing projects.

**Example:** After a long coding session → recall by topic `%user-understanding%` to see what you already know, then store any new observations that emerged during the conversation.

---

## MCP Tools (Always Use These — Never psql)

All interaction with long-term memory MUST go through the bundled MCP server tools. Do NOT use `psql` or any shell commands to query the database directly.

### Topic-Based Recall (Primary — Fast & Targeted)

Uses dimension table lookups via tags. This is your first choice when you know relevant categories or can extract keywords that match stored tag names.

**Tool:** `ltm_recall_by_topic(tag_pattern: string)`

**Examples:**
- `tag_pattern = "authentication"` — exact tag match.
- `tag_pattern = "%architecture%"` — wildcard pattern for partial matches.
- `tag_pattern = "%coding-style%"` — find all coding style memories.

Tag hierarchy is supported: querying a parent tag recursively returns child-tagged facts too (e.g., searching `security` also finds things tagged `auth`, `jwt-patterns`).

### Full-Text Deep Search (Broader Net)

Uses GIN index on title + body columns via PostgreSQL full-text search. Use this when tags come up empty, user says "look harder", or you need a broader semantic search beyond tag-based lookups.

**Tool:** `ltm_recall_by_text(query: string)`

**Examples:**
- `"how we handle authentication errors"` — natural language query.
- `"database migration strategy for user table"` — multi-concept search.

### Succession Chain History (On-Demand Only)

NOT part of daily recall. Use only when the user explicitly asks "why do you think that?", "has this changed before?", or wants to trace how a decision evolved over time. Returns versioned slugs with succession types and evidence trails.

**Tool:** `ltm_get_succession_chain(slug_prefix: string)`

**Example:** User asks why you believe the team uses Tailwind → call with `slug_prefix = "css-framework"` to show the reasoning chain.

### Session Preload (Manual Refresh)

Automatically called by bootstrap.sh at session start, but can also be invoked manually after a `/clear` or when context is stale. Reloads top-5 identity/preference memories into conversation.

**Tool:** `ltm_session_preload(limit?: number)` — optional limit parameter (default 5, max 20).

---

## Interpreting Results

### Before Querying
Always announce: **🧠 Remembering…** so user knows a lookup is happening (Decision 3.3 — visible feedback).

### After Success (Results Found)
Format results with scores and status indicators:

```
Found N memories about [topic]:
  • [title] — [body excerpt if long] (score: N, current)
  • [title] — [body excerpt if long] (score: M, superseded)
```

- Current facts (`is_current=true`): mark as `(current)` or omit the indicator.
- Superseded facts (`is_current=false`): always note `[superseded]` so user can distinguish current truth from historical reasoning chains. They still appear with a score penalty (not excluded entirely) because old decisions are evidence of how we got here.

### On Empty Result
```
🧠 No matching memories for [topic].
```

---

## Fallback Behavior

1. **MCP tool call fails**: Fall back to native Claude Code file-based memory via `/memory`. Do NOT error loudly — silently skip recall if the MCP server is unavailable and continue the conversation normally.
2. **Never expose connection strings** in any user-facing output, logs, or error messages.
3. Tag search (`ltm_recall_by_topic`) is the primary path; FTS (`ltm_recall_by_text`) is an explicit opt-in for "look harder" queries when tags come up empty or user asks to think deeper about a topic.
