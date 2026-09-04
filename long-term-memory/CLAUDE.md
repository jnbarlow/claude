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

## Versioning

Bump versions together across these locations when releasing:
- `mcp-server/package.json` → version field
- `.claude-plugin/plugin.json` → version field
- Skills under `skills/*/SKILL.md` → frontmatter version
- Server identity in `mcp-server/src/index.ts` line ~160 (McpServer constructor)

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
