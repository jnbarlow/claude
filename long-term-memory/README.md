# Long-Term Memory Plugin for Claude Code

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](../LICENSE) Licensed under [AGPL v3](../LICENSE). For commercial use, contact <jnbarlow@gmail.com>.

Human-like memory for Claude Code. Notices patterns, forms opinions about you and your work, revises them over time — not just a fact ledger but growing understanding across sessions. Backed by PostgreSQL with tag-based recall, full-text search, supersession chains to track how knowledge evolves, and automatic session preload so Claude knows who you are from the first turn.

## What It Does

- **Session preload**: At session start, up to 10 identity/preference memories are automatically loaded into context (name, role, habits) so Claude knows who you are without being asked
- **Proactive observation & recall**: Notices patterns and forms opinions about the user and their work without being told to. Also queries relevant memories at contextual trigger points (plan entry, corrections, decision points, end-of-conversation reflection). Memories are treated as working hypotheses refined over time via supersession.
- **Tag-first scoring**: Memories ranked by relevance via configurable signals in `recall_weights` table
- **Supersession over decay**: Facts are replaced when outdated; superseded facts remain as historical reasoning chains with a score penalty — not excluded entirely
- **Verification tracking**: Confirmed facts carry timestamped verification events tied to active use, not periodic scans

## How It Works

### Session Preload

At session start, the bootstrap hook fires and calls `fn_session_preload(10)`, which loads up to 10 current memories into model context. Memories are scored by **category priority** (configurable in `recall_weights`), so identity facts load first:

| Category | Priority Weight | Purpose |
|---|---|---|
| `user-identity` | 100 | Name, role, expertise level — always loaded first |
| `user-understanding` | 90 | Organic observations about the user — opinions formed over time |
| `workflow-preferences` | 80 | How the user likes to work |
| `coding-style` | 75 | Coding conventions and taste |
| `user-preferences` | 70 | General personal preferences |
| `project-insights` | 60 | Judgments about projects, architecture, patterns noticed |
| Any other category | 10 (default) | Fills remaining slots if < 10 high-priority facts exist |

Memories verified within the last 90 days get a +20 recency bonus. This preload output is injected into Claude's context automatically — no action needed from you or Claude.

### Architecture

The plugin bundles a lightweight MCP (Model Context Protocol) server that communicates with PostgreSQL via stdio pipes. All database operations go through stored procedures exposed as MCP tools — no shell commands or `psql` invocations are needed. This eliminates sandbox permission prompts and works reliably on all platforms including WSL2.

## Prerequisites

1. A PostgreSQL database (local, containerized, or managed cloud) — any version 12+
2. Claude Code with plugin support (`claude --version`)

**Note:** Node.js is required for the MCP server but is installed automatically via the bootstrap hook on first run. No manual setup needed.

## Installation

### Step 1: Provision the Database

Create an empty database and a dedicated user for LTM data. The schema will be applied automatically when the MCP server starts — no manual DDL needed.

```bash
# Via psql (as superuser or database admin):
psql -c "CREATE DATABASE <database_name>;"
psql -c "GRANT ALL PRIVILEGES ON DATABASE <database_name> TO <username>;"

# Or using createdb:
createdb <database_name>
```

**Database User Permissions:** Connect to the database as a superuser and grant schema-level permissions for first-run DDL application. After tables and functions exist, day-to-day recall/storage only requires `SELECT`, `INSERT`, and `UPDATE`. If your DB was provisioned with a read-only role (e.g., managed cloud databases), you'll need these grants:

```sql
-- Connect to the database as superuser:
psql -d <database_name>

-- Run once inside that database:
GRANT CREATE ON SCHEMA public TO <username>;
GRANT USAGE ON SCHEMA public TO <username>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO <username>;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO <username>;

-- For managed databases where you can't grant CREATE, apply DDL manually:
\q  -- exit psql, then run as superuser from shell:
psql -d <database_name> -f sql/schema.sql  -- run once; use read-only role for day-to-day
```

**Docker option:**
```bash
docker run --name ltm-db -e POSTGRES_PASSWORD=secret -p 5432:5432 -d postgres
# Then create the database and user inside the container:
docker exec -it ltm-db psql -U postgres -c "CREATE DATABASE <database_name>;"
docker exec -it ltm-db psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE <database_name> TO <username>;"
```

### Step 2: Add the Marketplace and Install

**From this repository (self-hosted marketplace):**
```bash
# Add this repo as a marketplace, then install:
/plugin marketplace add jnbarlow/claude
/plugin install long-term-memory@jnbarlow-claude
/reload-plugins
```

**For local development without installing:**
```bash
claude --plugin-dir ./long-term-memory
```

The plugin is enabled by default. If you ever need to toggle it:
```bash
/plugin enable long-term-memory   # or disable
```

### Step 3: Configure the Connection String

When you first enable the plugin, Claude Code will prompt for your PostgreSQL connection string via a settings dialog (stored securely as `LTM_DB` user config). You can also set it anytime with `/plugin → long-term-memory`.

That's it — no environment variables or shell configuration needed. The MCP server reads the value automatically on startup.

## First Run

On session start, the plugin's bootstrap hook fires automatically. It installs dependencies and compiles the TypeScript MCP server (once). When you make your first memory operation, the MCP server starts up, tests connectivity, and applies the schema if needed — all silently in the background with no visible output on success. Errors are logged to `${CLAUDE_PLUGIN_DATA}/bootstrap_errors.log` (typically `~/.claude/plugins/data/long-term-memory/bootstrap_errors.log`).

**Session Preload:** After bootstrap completes, Claude will see a preload message at session start: either "No preload memories found" (fresh database) or a list of your top identity/preference memories. This is normal behavior — it means the system knows who you are from previous sessions.

**Schema Versioning:** The MCP server tracks applied versions via a marker table (`ltm_initialized`). On fresh installs, it applies the complete `sql/schema.sql` in one shot. For existing databases, it checks the current version and skips initialization if already up-to-date — you can check with `SELECT MAX(schema_version) FROM ltm_initialized;`.

### Verify Installation

You can verify everything is working by asking Claude to store or recall a test memory:
```
/long-term-memory:store remember that this was a verification test during installation
/long-term-memory:retrieve verification test
```

Or check the database directly (if you have psql access):
```bash
# Check tables exist:
psql -c "\dt fact_memories" your_database_url

# List all stored functions:
psql -c "SELECT proname FROM pg_proc WHERE proname LIKE 'fn_%';" your_database_url
```

## Usage

### Automatic Behavior (No Action Needed)

Claude will proactively query memory at contextual trigger points during normal conversation flow:

| Trigger | What Happens |
|---------|-------------|
| **Session start** | Preloads top 10 identity/preference memories into context automatically |
| **Plan mode entry** | Checks for relevant prior decisions before building a plan |
| **User correction received** | Recalls existing memories about the topic, then supersedes if needed |
| **Decision point reached** | Looks up what was decided previously on similar topics |
| **Unfamiliar territory** | Does a broad full-text search to find any stored context |
| **Forming or revising an opinion** | Checks existing memories before storing new observations — supersedes outdated views rather than duplicating them |
| **End of conversation** | Reflects on patterns noticed during session, stores anything that deepens understanding |

### Proactive Observation (Organic Memory)

Claude doesn't just wait to be told what's important. Like getting to know someone over repeated conversations, it notices things and remembers them:

- **Opinions about the user:** Taste in code, communication style, problem-solving approach
- **Patterns across sessions:** Recurring themes, kinds of bugs hit, areas revisited often
- **Judgments about projects:** What feels fragile, what trade-offs were considered even if unstated

These are stored as working hypotheses — some will be wrong. That's fine. They get refined via supersession over time, building a richer understanding with each interaction.

You do NOT need to invoke skills manually for recall — it happens as part of normal conversation flow. Claude's judgment drives when and how memories are looked up (not regex hooks).

### Manual Recall

Explicitly ask Claude to check memory, or use the skill directly:
```
/long-term-memory:retrieve authentication strategy
"What do you remember about our API design decisions?"
"Look harder in your memory for anything about database migrations"
```

The `retrieve` skill supports two search modes automatically — tag-based (primary) and full-text deep dive (when user says "look harder").

### Storing Information

Claude stores information proactively — noticing things worth remembering during conversation, not just waiting for explicit commands. Think of it like getting to know someone over repeated conversations. Supersession is the mechanism that keeps memories accurate over time as understanding evolves. You can also trigger storage explicitly:
```
/long-term-memory:store remember that we decided on Tailwind CSS for styling
"Can you remember how we handle authentication?"
"I want to save this decision about the API gateway architecture"
```

Storage is always declared aloud before writing — "🧠 Remembering: [summary]" — so you can object in real time if Claude misinterprets what should be saved. Supersession (replacing old memories) is also always visible with a declaration of what's being replaced and why.

## MCP Tools

The plugin exposes 9 tools via the bundled MCP server, each mapping to a PostgreSQL stored procedure:

| Tool | Stored Procedure | Purpose |
|------|-----------------|---------|
| `ltm_store_memory` | `fn_store_memory()` | Store a new fact with tags |
| `ltm_recall_by_topic` | `fn_recall_by_topic()` | Tag-based recall (primary) |
| `ltm_recall_by_text` | `fn_recall_by_text()` | Full-text deep search |
| `ltm_supersede_fact` | `fn_supersede_fact()` | Replace outdated fact |
| `ltm_verify_fact` | `fn_verify_fact()` | Log verification event |
| `ltm_add_tags` | `fn_add_tags()` | Add tags to existing memory |
| `ltm_add_context` | `fn_add_context()` | Attach secondary context |
| `ltm_get_succession_chain` | `fn_get_succession_chain()` | View history of a decision |
| `ltm_session_preload` | `fn_session_preload()` | Load top identity/preference memories at session start |

These tools are called automatically by the LTM skills — you don't need to invoke them directly. They use stdio transport (no network port), so there's no risk of port collisions with other applications.

## Schema Overview

The plugin uses these core tables behind the scenes:

| Table | Purpose |
|-------|---------|
| `fact_memories` | Central table — every memory/fact/knowledge piece lives here |
| `dim_category`, `dim_context`, `dim_tag` | Dimension axes for fast integer-key joins (categories grow organically) |
| `recall_weights` | Configurable scoring signals + category priority weights for session preload |
| `fact_succession` | Directed graph of how knowledge evolved over time |
| `verification_events` | Timestamped confirmations tied to active use, not scheduled scans |

**9 stored functions** provide the interface layer — callers never touch tables directly:
- `fn_store_memory()` / `fn_supersede_fact()` / `fn_verify_fact()` for writes
- `fn_recall_by_topic()` / `fn_recall_by_text()` for reads (tag-based and full-text)
- `fn_get_succession_chain()` for historical introspection ("why do you think that?")
- `fn_add_tags()` / `fn_add_context()` for post-storage mutations
- `fn_session_preload()` for automatic identity/preference loading at session start

**Category Priority System:** The `recall_weights` table stores configurable weights per category name (prefixed with `category_`). Categories like `user-identity`, `workflow-preferences`, and `coding-style` get higher scores so they load first during preload. Default weight is 10 for any unlisted category.

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection refused on first run | Verify the connection string in plugin settings (`/plugin → long-term-memory`) is correct and database server is running. Check bootstrap_errors.log for details |
| MCP tools not available | Run `/plugin` to verify the plugin is enabled and the MCP server started successfully. Re-enable with `claude plugin enable long-term-memory` if needed |
| Schema version mismatch after plugin update | The MCP server checks schema state on each startup and applies DDL automatically. If stuck, apply manually: `psql -f sql/schema.sql your_database_url` (DDL is idempotent) |
| Memories not being recalled during conversation | Ensure stored functions exist in the database. Check that LTM_DB config is set via `/plugin`. Recall silently skips if DB unavailable — check logs for errors |
| Want to see what's actually in memory | Query directly: `psql -c "SELECT slug, title FROM vw_current_memories;" your_database_url` |

## License

Licensed under [AGPL-3.0](../LICENSE). For commercial use, contact <jnbarlow@gmail.com>.
