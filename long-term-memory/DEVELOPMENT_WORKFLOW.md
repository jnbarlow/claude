# Development Workflow — Testing Changes Without Reinstalling

How to test edits against the live plugin without reinstalling or copying files between two copies of the repo.

## The critical discovery: runtime loads from the cache, not the marketplace

Claude Code snapshots installed plugins into a **cache** directory and runs them from there:

```
~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/<version>/
```

The marketplace copy lives at:

```
~/.claude/plugins/marketplaces/jnbarlow-claude/long-term-memory/
```

**Editing the marketplace copy does NOT affect a running session.** The Stop-hook bug fix (missing `hookEventName`) sat in the marketplace dir for a while before it actually took effect — because Claude Code was executing the stale cached copy, not the marketplace one. Always test against the **cache** path.

## Testing workflow (symlink workspace → cache slot)

The workspace repo (`/home/jnbarlow/workspace/claude/long-term-memory`) is the source of truth. Symlink it into the matching cache version slot so runtime loads your live edits:

```bash
CACHE=~/.claude/plugins/cache/jnbarlow-claude/long-term-memory
ln -sfn /home/jnbarlow/workspace/claude/long-term-memory "$CACHE/1.1.6"
```

Then reload:

```
/reload-plugins
```

Or restart Claude Code entirely. Edits in the workspace now take effect on reload — no copying between locations.

## Back up before swapping (so you can restore cleanly)

The cache slot is a real directory with the stale copy. Move it aside first, then symlink:

```bash
CACHE=~/.claude/plugins/cache/jnbarlow-claude/long-term-memory
# 1. Backup the current cached version
mv "$CACHE/1.1.6" "$CACHE/1.1.6.orig-backup"
# 2. Symlink workspace into the slot
ln -sfn /home/jnbarlow/workspace/claude/long-term-memory "$CACHE/1.1.6"
```

### Restore the original cache copy later

```bash
CACHE=~/.claude/plugins/cache/jnbarlow-claude/long-term-memory
rm "$CACHE/1.1.6" && mv "$CACHE/1.1.6.orig-backup" "$CACHE/1.1.6"
```

## After editing TypeScript, rebuild the compiled output

The MCP server runs compiled JS from `mcp-server/dist/index.js`, not `src/`. Any `.ts` change is invisible until recompiled:

```bash
cd mcp-server && npx tsc
```

Symlinking does **not** skip this step. (Shell scripts and skill markdown are read live — no rebuild needed.)

## See also

- `TESTING_GUIDE.md` — how to exercise the hooks end-to-end once symlinking is set up.
