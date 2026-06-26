#!/usr/bin/env bash
# ltm_check_setup.sh — Prerequisite checker for LTM plugin
# Run this after installation to verify everything is configured correctly.

CONN=""
ERRORS=0

echo "=== Long-Term Memory Plugin Setup Check ==="
echo ""

# 1. Check psql client installed
if ! command -v psql >/dev/null 2>&1; then
    echo "[MISSING] PostgreSQL client tools (psql) not found."
    echo "  Install with:"
    echo "    Debian/Ubuntu: apt install postgresql-client"
    echo "    macOS:         brew install libpq"
    echo "    Windows:       Include psql in your WSL distro or use PostgreSQL installer"
    ERRORS=$((ERRORS + 1))
else
    PSQL_VER=$(psql --version | head -c 40)
    echo "[OK] $PSQL_VER"
fi

echo ""

# 2. Check connection string configured (userConfig env var or LTM_DB fallback)
if [ -n "${CLAUDE_PLUGIN_OPTION_LTM_DB_CONNECTION_STRING:-}" ]; then
    CONN="${CLAUDE_PLUGIN_OPTION_LTM_DB_CONNECTION_STRING}"
    echo "[OK] Database connection configured via plugin settings"

elif [ -n "${LTM_DB:-}" ]; then
    CONN="$LTM_DB"
    echo "[OK] Database connection configured via LTM_DB env var ($CONN)"

else
    echo "[WARN] No database connection found."
    echo "  Set one of:"
    echo "    • Plugin settings: configure 'ltm_db_connection_string' (recommended)"
    echo "    • Environment variable: export LTM_DB=\"postgresql://user@host/dbname\""
    ERRORS=$((ERRORS + 1))
fi

# Skip remaining checks if no connection string or psql not available
if [ -z "$CONN" ] || ! command -v psql >/dev/null 2>&1; then
    echo ""
    if [ $ERRORS -gt 0 ]; then
        echo "Fix the above issue(s) and re-run: bash \"${CLAUDE_PLUGIN_ROOT:-.}/scripts/ltm_check_setup.sh\""
    fi
    exit $ERRORS
fi

echo ""

# 3. Test connectivity to database
if ! psql "$CONN" -c '\q' >/dev/null 2>&1; then
    echo "[FAIL] Cannot connect to PostgreSQL at configured address."
    echo "  Check that the database server is running and connection string is correct."
    ERRORS=$((ERRORS + 1))

else
    DB_NAME=$(psql "$CONN" -tAc "SELECT current_database();" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$DB_NAME" ]; then
        echo "[OK] Connected to database: $DB_NAME"
    else
        echo "[OK] Database connection successful (could not determine DB name)"
    fi

    # 4. Verify schema tables exist
    TABLES=$(psql "$CONN" -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('fact_memories', 'dim_category', 'dim_tag', 'dim_context');" 2>/dev/null | tr -d '[:space:]')

    if [ "$TABLES" = "4" ]; then
        echo "[OK] All LTM tables present (schema bootstrapped)"
    elif [ "$TABLES" = "0" ]; then
        echo "[WARN] No LTM tables found — schema not yet applied."
        echo "  This is normal on first run. The bootstrap hook will apply it automatically."
    else
        echo "[WARN] Partial schema detected ($TABLES/4 tables). Check bootstrap_errors.log for issues:"
        DATA_DIR="${CLAUDE_PLUGIN_DATA:-~/.claude/plugins/data/long-term-memory}"
        echo "  $DATA_DIR/bootstrap_errors.log"
    fi

    # 5. Verify stored functions exist (expected: fn_store_memory, fn_recall_by_topic, etc.)
    FUNC_COUNT=$(psql "$CONN" -tAc "SELECT COUNT(*) FROM pg_proc WHERE proname IN ('fn_store_memory','fn_recall_by_topic','fn_recall_by_text','fn_supersede_fact','fn_verify_fact','fn_get_succession_chain','fn_add_tags','fn_add_context');" 2>/dev/null | tr -d '[:space:]')

    if [ "$FUNC_COUNT" = "8" ]; then
        echo "[OK] All stored functions present (8/8)"
    elif [ "$FUNC_COUNT" != "0" ] && [ -n "$FUNC_COUNT" ]; then
        echo "[WARN] Partial function set ($FUNC_COUNT/8). Bootstrap may not have completed."
    fi

    # 6. Check schema version if marker table exists
    VER=$(psql "$CONN" -tAc "SELECT COALESCE(MAX(schema_version),0) FROM ltm_initialized;" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$VER" ]; then
        echo "[OK] Schema version: $VER"
    fi

fi

echo ""

# Summary
if [ $ERRORS -eq 0 ]; then
    echo "✓ Setup complete — LTM plugin is ready to use."
else
    echo "✗ Found $ERRORS issue(s). Fix them and re-run this check script."
    echo ""
    echo "If Claude prompts for permission when running psql commands, add this"
    echo "to your .claude/settings.json (or let the first invocation prompt you):"
    echo '  { "permissions": { "alwaysAllow": [ "Bash(psql)" ] } }'
fi

exit $ERRORS
