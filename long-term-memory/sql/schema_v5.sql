-- Schema migration v4 -> v5: Add memory inventory + soft-delete route.
-- fn_list_memories() lets callers enumerate stored memories (for duplicate detection,
-- quality review, and cleanup) without querying the database directly. Bodies are
-- returned in full so duplicates can be judged — unlike recall tools that truncate.
-- fn_delete_fact() soft-deletes a memory row (is_deleted = true, deleted_at stamped);
-- rows stay in the table for audit/recovery until a future purge job removes them after
-- a grace window (deferred until telemetry supports it). This is reversible cleanup
-- (e.g. consolidating duplicates), not routine.

BEGIN;

-- Soft-delete columns on fact_memories. Orthogonal to is_current (supersession): a row can be
-- superseded AND soft-deleted independently. Active-only filters match on is_deleted = false.
ALTER TABLE fact_memories ADD COLUMN IF NOT EXISTS is_deleted BOOLEAN DEFAULT false;
ALTER TABLE fact_memories ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ NULL;

-- Function 10: Enumerate stored memories for review / duplicate detection / cleanup.
-- No required filter so it can list everything; caller may pass a smaller limit to cap
-- output size. Body returned in full (not truncated) so reviewers can judge content.
CREATE OR REPLACE FUNCTION fn_list_memories(
    p_limit INTEGER DEFAULT 200
) RETURNS TABLE (
    fact_id         INTEGER,
    slug            TEXT,
    title           TEXT,
    body            TEXT,
    is_current      BOOLEAN,
    category        VARCHAR(50),
    primary_context TEXT,
    tags            TEXT[],
    created_at      TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        fm.id::INTEGER          AS fact_id,
        fm.slug::TEXT           AS slug,
        fm.title::TEXT          AS title,
        fm.body                 AS body,
        fm.is_current           AS is_current,
        dc.category_name::VARCHAR(50)  AS category,
        dctx.context_name::TEXT            AS primary_context,
        (SELECT ARRAY_AGG(dt.tag_name::TEXT ORDER BY dt.tag_name)
         FROM fact_memory_tags ft3
         JOIN dim_tag dt ON ft3.tag_key = dt.tag_key
         WHERE ft3.memory_id = fm.id)      AS tags,
        fm.created_at           AS created_at
    FROM fact_memories fm
    JOIN dim_category dc       ON fm.category_key = dc.category_key
    LEFT JOIN dim_context dctx ON fm.context_key   = dctx.context_key
    WHERE fm.is_deleted = false
    ORDER BY fm.is_current DESC, fm.updated_at DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql STABLE;


-- Function 11: Soft-delete a memory by slug (reversible cleanup). Marks the row is_deleted = true and
-- stamps deleted_at so it drops out of all active recall/list/preload paths while remaining in the table
-- for audit/recovery. A future purge job can physically remove rows after a grace window (deferred until
-- telemetry supports it). Returns -1 gracefully (not an exception) if no current, non-deleted fact matches,
-- matching the graceful-fail convention of fn_supersede_fact / fn_verify_fact so silent background
-- operations don't crash mid-conversation.
CREATE OR REPLACE FUNCTION fn_delete_fact(
    p_slug TEXT
) RETURNS INTEGER AS $$
DECLARE
    v_mem_id INTEGER;
BEGIN
    -- Resolve slug to current, non-deleted fact (graceful: return -1 if not found instead of crashing).
    SELECT id INTO v_mem_id FROM fact_memories WHERE slug = p_slug AND is_current = true AND is_deleted = false;
    IF NOT FOUND THEN
        RAISE NOTICE 'fn_delete_fact: no current memory found with slug "%".', p_slug;
        RETURN -1;  -- not found — caller can ignore silently for cleanup attempts
    END IF;

    UPDATE fact_memories SET is_deleted = true, deleted_at = NOW() WHERE id = v_mem_id AND is_deleted = false;
    RETURN v_mem_id;
END;
$$ LANGUAGE plpgsql;


COMMIT;

-- Record this version as applied (outside transaction for safety)
INSERT INTO ltm_initialized (schema_version) VALUES (5) ON CONFLICT DO NOTHING;
