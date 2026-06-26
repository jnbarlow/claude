---
name: ltm-store
description: |
  Store facts, decisions, preferences, and context into PostgreSQL long-term memory using the bundled MCP server. Use this skill when important information should be remembered across sessions.
allowed-tools: Read
version: "1.0.0"
tags: [memory, postgresql, storage]
---

# Long-Term Memory Storage

## When to Store Information

Proactively persist the following during conversation flow. Think of this like human memory — notice things, form opinions, record them, revise later when new information arrives. Use judgment — do NOT store everything transient or obvious from code alone.

### 0. Organic Observations (New — Proactive & Independent)
**This is the default mode.** Like getting to know someone over repeated conversations, observe and remember things without being explicitly told they matter:

- **Opinions you form about the user:** Their taste in code, communication style, what they value (speed vs elegance, minimalism vs thoroughness), how they approach problems.
- **Patterns you notice:** Recurring themes in their work, kinds of bugs they hit, areas they tend to revisit.
- **Judgments about projects or topics:** "This architecture feels fragile because...", "They seem to prefer X pattern but haven't articulated it."
- **Context that emerges naturally:** Why a decision was made (read between the lines), what trade-offs were considered even if unstated.

**Treat stored memories as working hypotheses, not gospel.** Some will be wrong — that's fine. Use `ltm_supersede_fact` when new evidence contradicts or deepens an earlier opinion. The supersession chain IS the story of growing understanding.

**Examples:**
- User writes a very terse commit message but their code is meticulous → store: *"John cares about code quality even if he doesn't always document it verbosely."*
- User pushes back on over-engineering twice in different contexts → store an opinion about that preference, even though they never said "I prefer simple."
- After several sessions, you realize your early assessment was incomplete → supersede with the refined view.

**Category:** `user-understanding`, `project-insights`, or whatever domain fits.

### 1. Corrections Received (Highest Priority)
When the user corrects you ("actually we use X not Y"), this is a signal that stored knowledge may be wrong. First recall existing memories about the topic, then supersede if needed rather than adding contradictory facts. Category: `workflow-preferences`, `coding-style`, or domain-specific (`geoswitch-decisions`).

### 2. Decisions Landed After Debate
When a technical decision is reached after considering alternatives (architecture choice, library selection, API design), store the decision AND its rationale. This preserves reasoning for future reference when similar decisions arise. Category: describe WHAT it's about — `geoswitch-architecture`, not abstract types like "decision".

### 3. User Preferences Revealed
When user states explicit preferences they haven't mentioned before ("I always prefer X over Y", "we never do Z in this project"), store them so you can apply those conventions going forward without being told again. Category: `workflow-preferences`, `coding-style`.

### 4. Non-Obvious Facts Worth Preserving
When discovering facts during active work that aren't derivable from the codebase itself (business context, deployment constraints, team agreements), store them if they'll inform future sessions. Whatever domain fits — categories grow organically.

**Category naming rule:** Pick names describing *what* a memory is about (`campaign-characters`, `geoswitch-decisions`), not abstract types like "decision" or "preference". If nothing fits, make one up — the stored function auto-creates on first use via upsert. No predefined buckets; categories grow organically from content domains (Decision 3.1).

---

## MCP Tools (Always Use These — Never psql)

All interaction with long-term memory MUST go through the bundled MCP server tools. Do NOT use `psql` or any shell commands to query the database directly.

### Store a New Fact (Primary)

Auto-resolves category, context, and tags by name (idempotent). Returns the new fact_id. Raises exception if slug already exists as current — use `ltm_supersede_fact` instead in that case.

**Tool:** `ltm_store_memory(slug: string, category: string, context: string, title: string, body: string, tags?: string[])`

```
Example call:
  ltm_store_memory(
    slug = "auth-strategy-jwt",           // unique per current memory
    category = "authentication-decisions", // auto-created if missing
    context = "$PROJECT_NAME",            // project name or path
    title = "JWT-based authentication chosen over sessions",
    body = "We decided to use JWT tokens for stateless auth because the API is public-facing and needs to work with mobile clients. Session cookies would require CSRF protection which adds complexity.",
    tags = ["authentication", "security", "architecture"]  // optional; auto-created
  )

Feedback: 🧠 Remembering: JWT-based authentication chosen over sessions → Saved ✓
```

**Slug conventions:** Use kebab-case, descriptive but concise. Include domain prefix if memories span multiple areas (`auth-strategy-jwt`, `css-framework-tailwind`). The slug is the stable identifier — future supersessions reference it by name.

### Supersede an Existing Fact (Correction)

Use when a stored memory becomes outdated or incomplete due to new information, user correction, or discovered contradiction. Marks old fact as superseded and creates versioned copy (`_v1`, `_v2`...). Returns `-1` gracefully if slug not found — never crashes mid-conversation.

**Tool:** `ltm_supersede_fact(slug: string, new_title: string)`

```
Example call:
  ltm_supersede_fact(
    slug = "css-framework-tailwind",     // old slug being replaced
    new_title = "CSS Framework switched to vanilla + utility classes"
  )

Feedback: 🔄 Superseded: CSS framework changed from Tailwind to vanilla + utilities ✓
```

**Succession types:**
- `supersedes` — direct contradiction; the old fact is wrong.
- `refines` — more precise version of the same idea (same direction, added detail).
- `contextualizes` — was right but incomplete; here's additional context that changes interpretation.

### Verify a Fact (Silent Confirmation)

Log timestamped verification event when using a recalled memory successfully during active work. Returns status code (`0`=success, `-1`=not found instead of crashing mid-conversation). Per Decision 4.1: routine confirmations log quietly — no visible output needed unless user explicitly asks for verification feedback.

**Tool:** `ltm_verify_fact(slug: string, result_val: string)`

```
Example call (silent background confirmation):
  ltm_verify_fact(
    slug = "auth-strategy-jwt",
    result_val = "confirmed"   // or "superseded"
  )
```

### Add Tags to Existing Fact (Post-Storage Mutation)

Add tags after initial storage without replacing existing ones. Auto-resolves tag names by name (idempotent). Only adds missing; existing unchanged. Graceful silent fail if slug not found.

**Tool:** `ltm_add_tags(slug: string, tags: string[])`

```
Example call:
  ltm_add_tags(
    slug = "auth-strategy-jwt",
    tags = ["api-design"]
  )
```

### Add Context to Existing Fact (Post-Storage Mutation)

Attach secondary context via bridge table post-storage. A memory learned in one project may be relevant to several others. Auto-resolves context by name (idempotent). Only adds missing; existing unchanged. Graceful silent fail if slug not found.

**Tool:** `ltm_add_context(slug: string, context_name: string)`

```
Example call:
  ltm_add_context(
    slug = "auth-strategy-jwt",
    context_name = "related-project-name"
  )
```

---

## User-Visible Feedback Patterns

Always provide feedback on storage actions (Decision 3.3):

| Action | Before Query | After Success |
|--------|-------------|---------------|
| **New memory** | `🧠 Remembering: [one-liner summary]` | `Saved ✓` |
| **Supersession** | Declare aloud what's being replaced and why (Decision 4.2 — always visible) | `🔄 Superseded ✓` |

**Examples:**
```
🧠 Remembering: JWT-based authentication chosen over sessions → Saved ✓
🧠 Updated: CSS framework switched to vanilla + utilities 🔄 Superseded ✓
✓ Verified memory about auth strategy during implementation review (only when user explicitly asks)
```

---

## Routing Rule

When plugin is active (`LTM_DB` configured), all "remember" commands default to PostgreSQL LTM. To explicitly use native Claude Code file-based memory instead, invoke `/memory [text]`. The presence of `LTM_DB` config is the signal — no special phrases needed (Decision 3.5).

---

## Important Notes

- Storage is proactive — like human memory, notice things and remember them without being told to. Form opinions, observe patterns, record judgments about the work and the user.
- Treat memories as working hypotheses that get refined over time via supersession. Being wrong initially is fine; it's how understanding grows.
- Do NOT store transient information or things already obvious from reading the codebase.
- Always provide user-visible feedback on storage actions so transparency is maintained.
- If an MCP tool call fails, silently skip; do not error loudly mid-conversation.
