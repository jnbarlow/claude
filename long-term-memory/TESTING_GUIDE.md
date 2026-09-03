# Testing Guide for LTM Proactive Hooks

## Quick Test Setup (Safest)

Instead of removing the installed plugin, you can test by **temporarily replacing** the installation with a symlink to your workspace version:

### Step 1: Backup Current Installation

```bash
cd ~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/
mv 1.1.0 1.1.0-backup-$(date +%Y%m%d)
echo "Backup created at: $(pwd)/1.1.0-backup-$(date +%Y%m%d)"
```

### Step 2: Create Symlink to Workspace Version

```bash
ln -s /home/jnbarlow/workspace/claude/long-term-memory 1.1.0
echo "Symlink created — workspace version will be used"
```

### Step 3: Reload Plugins in Claude Code

In your Claude Code session, run:
```
/reload-plugins
```

Or restart Claude Code entirely.

### Step 4: Test the Hooks

**Test UserPromptSubmit hook:**
1. Submit a prompt like: "How should we handle authentication?"
2. Check if relevant memories are injected into context (look for 🧠 Relevant memories found in your transcript)
3. Try with short prompts ("hi") — verify no injection occurs

**Test Stop hook:**
1. Have Claude make a decision: "Let's use JWT for auth"
2. Wait for response to complete
3. Check stderr output for: `[Stop] Stored memory: ...`
4. Verify memory was stored by running `/long-term-memory:retrieve` with topic "jwt" or "authentication"

### Step 5: Restore Original (if needed)

```bash
rm ~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/1.1.0
mv ~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/1.1.0-backup-$(date +%Y%m%d) 1.1.0
echo "Original installation restored"
```

## Component Testing (Optional)

You can test individual components without full integration:

### Test MCP Invocation Helper

```bash
# From the long-term-memory directory
export CLAUDE_PLUGIN_ROOT="/home/jnbarlow/workspace/claude/long-term-memory"

# Test recall with OR mode (default)
node scripts/mcp-invoke.js ltm_recall_by_text --query "authentication"

# Test store memory
node scripts/mcp-invoke.js ltm_store_memory \
  --slug "test-hook-storage" \
  --title "Test Memory" \
  --body "This is a test memory from hooks testing" \
  --category "test" \
  --context "manual-test"
```

### Test Schema Migration

The MCP server will automatically apply `schema_v2.sql` on next startup if your schema_version is < 2. To verify:

1. Check current version in database (requires DB access):
   ```sql
   SELECT schema_version FROM ltm_initialized;
   ```

2. Or check MCP logs when reloading plugins — should see migration applied message.

## Debugging

### Enable Debug Logging

The hooks write debug info to stderr. To capture it:

1. In Claude Code, run commands that trigger the hooks
2. Check your terminal output for messages like:
   - `[UserPromptSubmit] evaluated prompt=...`
   - `[Stop] Stored memory: ...`

### Common Issues

**Hook not firing:**
- Verify `hooks.json` has correct structure (check with `jq '.' hooks/hooks.json`)
- Ensure scripts are executable: `chmod +x scripts/*.sh scripts/*.js`
- Check CLAUDE_PLUGIN_ROOT is set correctly

**MCP invocation fails:**
- Ensure MCP server is running (check `mcp-server/dist/index.js` exists)
- Verify database connection string is configured
- Check `~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/1.1.0/mcp-server/` has compiled files

**Schema migration not applied:**
- MCP server applies migrations on startup — reload plugins or restart Claude Code
- Check database for schema_version: `SELECT * FROM ltm_initialized;`

## Verification Checklist

After testing, verify:

- [ ] UserPromptSubmit hook fires on user prompts
- [ ] Relevant memories are injected into context (full content, no truncation)
- [ ] Short prompts (< 5 chars) don't trigger injection
- [ ] Stop hook detects decision patterns ("we should", "let's use")
- [ ] Memories are auto-stored with guards (session limit: 5)
- [ ] Duplicate check prevents redundant storage
- [ ] Schema v2 migration applied successfully
- [ ] OR mode works for broader recall (default behavior)

## Rollback Plan

If anything breaks, restore the backup:

```bash
cd ~/.claude/plugins/cache/jnbarlow-claude/long-term-memory/
rm -rf 1.1.0
mv 1.1.0-backup-* 1.1.0
# Then reload plugins in Claude Code
```