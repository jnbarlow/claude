# LTM Plugin — Claude Code Notes

## Critical: Always Rebuild After TypeScript Changes

The MCP server runs compiled JavaScript from `mcp-server/dist/index.js`, NOT the source in `src/`. Any edits to `.ts` files are invisible at runtime until recompiled.

**After editing any file under `mcp-server/src/`:**
```bash
cd mcp-server && npx tsc
```

If you skip this step, Claude Code will keep running stale code and changes won't take effect — even with a fresh session or plugin reload. This is the #1 reason for "why isn't my change working?" when developing locally.

## Schema Migrations

- `sql/schema.sql` = current full DDL (applied on fresh installs)
- `sql/schema_v*.sql` = incremental migration files discovered by bootstrap at runtime
- Bootstrap checks MAX(schema_version) in DB, then applies any pending migrations sequentially
- When adding a new migration: create the SQL file AND recompile TypeScript if you touch index.ts
- **ALWAYS backport every migration into `sql/schema.sql`** — bump its version marker to match (line ~816: `VALUES (<n>)`) and copy the exact function/DDL changes into the inline definition. schema.sql is the fresh-install path; if a migration isn't reflected there, a clean install ships with the bug. This is easy to miss when focused on runtime migrations — treat it as part of "add a migration," not optional.

## Testing Schema & Functions (preferred over plugin mapping for most work)

Most schema/function/tool changes can be tested directly against PostgreSQL without wiring up the MCP server or remapping the plugin. This is far faster and more reliable than plugin-mapping round-trips, which are still needed for transport/config/secret-resolution paths but not for SQL logic.

**Setup:** use an isolated **schema** (not a new database) inside your existing LTM database — the `claude_ltm` role can't create databases, but it can create schemas. Everything runs in `ltm_v5_test`, leaving real data untouched:

```bash
export PGPASSWORD=claude_ltm
PSQL="psql postgresql://claude_ltm:claude_ltm@postgres.flamingcow.org:5432/claude_ltm"

# Isolated schema for this round of testing
$PSQL -c "DROP SCHEMA IF EXISTS ltm_v5_test CASCADE; CREATE SCHEMA ltm_v5_test;"
$PSQL -c "SET search_path TO ltm_v5_test, public;"

# Apply the full master schema (fresh-install path) as a baseline
$PSQL -f sql/schema.sql
```

**Test a migration exactly as bootstrap does:** apply the current schema first, bump the marker to the prior version, then run only the new migration file:

```bash
$PSQL -c "SET search_path TO ltm_v5_test, public;" <<'SQL'
\i sql/schema.sql
UPDATE ltm_initialized SET schema_version = 4 WHERE schema_version = 5;  -- pretend we're on v4
\i sql/schema_v5.sql   -- bootstrap would run this next
SQL
```

**Smoke-test the new functions** (store → list → supersede → delete, plus the graceful `-1` miss):

```bash
$PSQL -c "SET search_path TO ltm_v5_test, public;" <<'SQL'
SELECT fn_store_memory('smoke', 'test-cat', 'proj', 'Smoke test', 'Body text.', ARRAY['smoke']);
SELECT slug FROM fn_list_memories(10);
SELECT fn_delete_fact('smoke');          -- returns the deleted id
SELECT fn_delete_fact('nope-missing');   -- should return -1 gracefully, not throw
SQL
```

**Always clean up afterward:** `$PSQL -c "DROP SCHEMA ltm_v5_test CASCADE;"` — never leave test residue in production.

When plugin mapping is still needed: secret resolution, HTTP transport, stdio bootstrapping, and end-to-end tool invocation through the actual MCP server.

## Versioning

Bump versions together across these locations when releasing:
- `mcp-server/package.json` → version field
- `.claude-plugin/plugin.json` → version field
- Skills under `skills/*/SKILL.md` → frontmatter version
- Server identity in `mcp-server/src/index.ts` line ~202 (McpServer constructor)

## Commit Messages

**Issue branches (`issue-\d+`):** Prefix with issue number.
```
# Branch: issue-3
commit: "issue-3: fixed OR mode tsquery and bumped version to 1.1.1"
```

**Other branches:** Fall back to conventional commits (feat/fix/chore/docs).
```
# Branch: main or feature/x
commit: "fix(ltm): handle missing migration gracefully"
```

**Never include `Co-Authored-By: Claude` lines** in commit messages.

## Hooks & Debug Logs (dev notes)

Three hooks drive proactive memory capture / recall. Each has a debug log so you can verify behavior without instrumenting the MCP server.

| Hook | Script | Debug log |
|------|--------|-----------|
| `SessionStart` | `scripts/bootstrap.sh` | — |
| `UserPromptSubmit` | `scripts/user-prompt-eval.sh` | `${CLAUDE_PLUGIN_DATA}/ltm_user_prompt_eval_debug.log` |
| `Stop` (auto-store) | `scripts/stop-eval.sh` | `${CLAUDE_PLUGIN_DATA}/ltm_stop_hook_debug.log` |

`${CLAUDE_PLUGIN_DATA}` defaults to `~/.claude/plugins/data/long-term-memory`. Logs are **rotated daily at session start** by `bootstrap.sh`: each active log is archived to `<log>.<YYYY-MM-DD>` and reset, keeping only the newest 7 archives. Rotation runs once per calendar day (gated by a marker file) — same-day bootstrap re-runs are a no-op. If you're debugging and want a clean slate, delete both `.log` files; they regenerate on next hook fire.

**Testing hooks without a full session:** `user-prompt-eval.sh` reads JSON from stdin (`{"prompt": "..."}`) and hits the MCP server over HTTP at the port in `${CLAUDE_PLUGIN_DATA}/ltm-mcp-port.txt`. You can point it at a fake endpoint for local checks. The Stop hook similarly takes `{stop_hook_active, last_assistant_message}` on stdin.
