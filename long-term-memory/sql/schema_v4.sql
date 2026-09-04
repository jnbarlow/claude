-- Schema migration v3 -> v4: Fix OR mode tsquery construction in fn_recall_by_text.
-- The previous implementation used array_to_string() which produces plain text,
-- not a valid tsquery expression — multi-word queries like "decision react vue"
-- returned zero results because PostgreSQL couldn't parse the concatenated string
-- as a proper tsquery with | (OR) operators between lexemes.
--
-- Fix: iterate over query words and join each cast to tsquery with || operator,
-- which produces a valid tsquery OR expression in PostgreSQL.

BEGIN;

CREATE OR REPLACE FUNCTION fn_recall_by_text(
    p_query       TEXT,
    p_current_ctx TEXT DEFAULT NULL,
    p_mode        TEXT DEFAULT 'OR'  -- 'AND' or 'OR', defaults to 'OR' for broader recall
) RETURNS TABLE (
    fact_id         INTEGER,
    slug            TEXT,
    title           TEXT,
    body            TEXT,
    is_current      BOOLEAN,
    category        VARCHAR(50),
    relevance_score  INTEGER,
    primary_context TEXT,
    tags            TEXT[]
) AS $$
DECLARE
    v_ctx_key       SMALLINT;
    w_tag_hit       SMALLINT := 30;
    w_ctx_match     SMALLINT := 50;
    w_recency       SMALLINT := 20;
    w_succ_penalty  SMALLINT := -10;
    v_tsquery       tsquery;
BEGIN
    -- Load weights from config table (defaults above used if row missing).
    SELECT weight_value INTO w_tag_hit      FROM recall_weights WHERE signal_name = 'tag_hit';
    SELECT weight_value INTO w_ctx_match    FROM recall_weights WHERE signal_name = 'context_match';
    SELECT weight_value INTO w_recency      FROM recall_weights WHERE signal_name = 'recency_bonus';
    SELECT weight_value INTO w_succ_penalty FROM recall_weights WHERE signal_name = 'succession_penalty';

    -- Resolve current context if provided.
    IF p_current_ctx IS NOT NULL THEN
        SELECT context_key INTO v_ctx_key FROM dim_context WHERE context_name = p_current_ctx;
    END IF;

    -- Build tsquery based on mode: OR (default, broader) or AND (strict).
    IF p_mode = 'AND' THEN
        v_tsquery := plainto_tsquery('english', p_query);  -- AND between terms (strict matching)
    ELSE
        -- OR mode: split query into words, cast each to tsquery, join with | operator.
        -- Each word is lexeme-processed via ::tsquery; the || operator on tsquery values
        -- produces a proper tsquery OR expression in PostgreSQL.
        DECLARE
            v_word TEXT;
            v_first BOOLEAN := true;
        BEGIN
            v_tsquery := NULL;
            FOR v_word IN
                SELECT trim(both ' ''"' from value)
                FROM unnest(string_to_array(p_query, ' ')) AS value
                WHERE length(trim(both ' ''"' from value)) > 0
            LOOP
                IF v_first THEN
                    v_tsquery := v_word::tsquery;
                    v_first := false;
                ELSE
                    v_tsquery := v_tsquery || ' | ' || v_word::tsquery;
                END IF;
            END LOOP;

            -- If no words survived filtering, default to a query that matches nothing.
            IF v_tsquery IS NULL THEN
                v_tsquery := '''nonexistentwordxyz'''::tsquery;
            END IF;
        END;
    END IF;

    RETURN QUERY
    WITH hit AS (
        SELECT fm.id  AS fact_id,
               fm.slug::TEXT         AS slug,
               fm.title::TEXT       AS title,
               fm.body             AS body,
               fm.is_current   AS is_current,
               dc.category_name::VARCHAR(50)    AS category,
               dctx.context_name::TEXT          AS primary_context,

               -- Base score: FTS rank (normalized 0-1 scaled to ~40 points max), plus configurable signals.
               (ts_rank(to_tsvector('english', fm.title || ' ' || fm.body), v_tsquery) * 40)::INTEGER
             + CASE WHEN NOT fm.is_current THEN w_succ_penalty ELSE 0 END
             + CASE WHEN v_ctx_key IS NOT NULL
                        AND (fm.context_key = v_ctx_key OR EXISTS (
                            SELECT 1 FROM fact_memory_contexts_bridge fcbr
                            WHERE fcbr.memory_id = fm.id AND fcbr.context_key = v_ctx_key
                        ))
                    THEN w_ctx_match ELSE 0 END
             + CASE WHEN tag_hits > 0 THEN w_tag_hit * LEAST(tag_hits, 3) ELSE 0 END
             + CASE WHEN fm.created_at >= NOW() - INTERVAL '90 days' THEN w_recency ELSE 0 END
               AS relevance_score,

               -- Count of matching tags (capped for scoring).
               (SELECT COUNT(*) FROM fact_memory_tags_bridge fmbt
                JOIN dim_tag dt ON dt.tag_key = fmbt.tag_key
                WHERE fmbt.memory_id = fm.id
                  AND dt.tag_name ILIKE ANY(ARRAY(SELECT trim(both ' ''"' from value)
                                                   FROM unnest(string_to_array(p_query, ' ')) AS value
                                                   WHERE length(trim(both ' ''"' from value)) > 0)))::SMALLINT
                 AS tag_hits

        FROM fact_memories fm
        JOIN dim_category dc ON dc.category_key = fm.category_key
        LEFT JOIN dim_context dctx ON dctx.context_key = fm.context_key

        -- Full-text search filter: title || body must match the tsquery.
        WHERE to_tsvector('english', fm.title || ' ' || fm.body) @@ v_tsquery

        ORDER BY relevance_score DESC, fm.created_at DESC
        LIMIT 50
    )
    SELECT fact_id, slug, title, body, is_current, category, relevance_score, primary_context, NULL::TEXT[] AS tags
    FROM hit;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

-- Update schema version marker (outside transaction for safety).
COMMIT;
INSERT INTO ltm_initialized (schema_version) VALUES (4) ON CONFLICT DO NOTHING;
