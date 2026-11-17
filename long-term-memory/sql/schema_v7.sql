-- Schema migration v6 -> v7: Fix fn_recall_by_text OR-mode FTS stemming bug.
--
-- Root cause: the OR-mode tsquery was built by quoting each raw query word with
-- quote_literal(lower(...)) — e.g. 'database'::tsquery. A quoted tsquery lexeme is
-- matched EXACTLY and is never stemmed, but to_tsvector('english', …) stores STEMMED
-- lexemes (e.g. 'databas'). So a query for "database" could never match a vector that
-- contains only 'databas' — recall_by_text returned zero rows for every query even when
-- the word was literally present in a memory body. This made ltm_recall_by_text dead: the
-- UserPromptSubmit hook fired but had nothing to inject, so per-submission auto-retrieval
-- silently never happened.
--
-- Fix: derive each lexeme FROM its own to_tsvector (which both stems and quotes safely),
-- then quote_literal() those actual lexemes and OR-join them. This preserves the special
-- character safety that quote_literal provided ("C++ & Rust" -> 'c' | 'rust', literal, not
-- operators) while matching stemmed vectors correctly. Plaintext words with no lexemes still
-- fall through to the existing "match nothing" sentinel below.

BEGIN;

CREATE OR REPLACE FUNCTION fn_recall_by_text(
    p_query       TEXT,
    p_current_ctx TEXT DEFAULT NULL,
    p_mode        TEXT DEFAULT 'OR'  -- NEW: 'AND' or 'OR', defaults to 'OR' for broader recall
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
        -- OR mode: derive each lexeme from its own to_tsvector('english', word), which both
        -- stems the word and quotes it safely. quote_literal() on the resulting lexemes keeps
        -- bare & / | / ( ) etc. as search text rather than tsquery syntax — so "C++ & Rust"
        -- matches those words literally ('c' | 'rust') instead of throwing a tsquery error.
        -- string_agg builds the whole expression and casts ONCE; building incrementally with ||
        -- ' | ' on tsquery values would fail ('syntax error in tsquery: " | "'). NULL when no
        -- words survive -> fall back to a query that matches nothing (see below).
        SELECT string_agg(quote_literal(l), ' | ')::tsquery
          INTO v_tsquery
          FROM unnest(string_to_array(p_query, ' ')) AS value
               , LATERAL (SELECT tsvector_to_array(to_tsvector('english', value)) AS lex) t
               , UNNEST(t.lex) AS l
          WHERE length(trim(value)) > 0;

        -- If no words survived filtering, default to a query that matches nothing.
        IF v_tsquery IS NULL THEN
            v_tsquery := '''nonexistentwordxyz'''::tsquery;
        END IF;
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
                         )) THEN w_ctx_match ELSE 0 END
             + CASE WHEN EXISTS (
                    SELECT 1 FROM verification_events ve
                    WHERE ve.memory_id = fm.id
                      AND ve.recorded_at > NOW() - INTERVAL '90 days'
                      AND ve.result = 'confirmed'
                 ) THEN w_recency ELSE 0 END
             AS relevance_score_final

        FROM fact_memories fm
        JOIN dim_category dc   ON fm.category_key = dc.category_key
        JOIN dim_context dctx  ON fm.context_key   = dctx.context_key
        WHERE fm.is_deleted = false AND to_tsvector('english', fm.title || ' ' || fm.body) @@ v_tsquery
    )
    SELECT h.fact_id, h.slug, h.title, h.body, h.is_current, h.category,
           h.relevance_score_final,
           h.primary_context,
           (SELECT ARRAY_AGG(dt.tag_name::TEXT ORDER BY dt.tag_name)
            FROM fact_memory_tags ft3 JOIN dim_tag dt ON ft3.tag_key = dt.tag_key
            WHERE ft3.memory_id = h.fact_id)

    FROM hit h
    ORDER BY h.relevance_score_final DESC;

END;
$$ LANGUAGE plpgsql;

-- Update schema version marker (outside transaction for safety).
COMMIT;
INSERT INTO ltm_initialized (schema_version) VALUES (7) ON CONFLICT DO NOTHING;
