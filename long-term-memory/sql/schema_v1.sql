-- LTM Schema v1.0.0 -- Applied by bootstrap.sh on SessionStart
-- ============================================================
-- PostgreSQL Long-Term Memory Schema (DDL)
-- Generated from design discussion: 2026-06-21
-- Hardened with Phase 5 audit fixes: 2026-06-22
-- Star topology with dimension tables + fact table at center
-- Supersession chain replaces confidence decay model
-- ============================================================

BEGIN;

-- Marker table (idempotent — IF NOT EXISTS). Bootstrap script checks this table to decide whether DDL needs running.
CREATE TABLE IF NOT EXISTS ltm_initialized (
    schema_version INTEGER PRIMARY KEY,          -- current DDL version applied to this DB
    applied_at     TIMESTAMPTZ DEFAULT NOW()     -- when this version was last bootstrapped
);

-- NOTE: All CREATE TABLE/INDEX statements use IF NOT EXISTS so this file is fully idempotent on re-runs.
-- Control logic (version checks, migration decisions) lives in the bootstrap script — not here.

-- -----------------------------------------------------------
-- DIMENSION TABLES (small, stable, fast joins)
-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_category (
    category_key  SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    category_name VARCHAR(50) UNIQUE NOT NULL   -- campaign-characters, geoswitch-decisions, workflow-preferences ... grows organically
);

-- No seed data. Categories grow dynamically via fn_store_memory() upsert on first use.
COMMENT ON TABLE dim_category IS 'Axis: what kind of memory this is — grows organically from storage calls';

-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_context (
    context_key  SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    context_name VARCHAR(120) NOT NULL,          -- project path or session descriptor
    is_active    BOOLEAN DEFAULT true             -- mark inactive without deleting attached memories
);

-- Partial unique index: only one active row per name. Inactive rows free the constraint so reactivation works.
CREATE UNIQUE INDEX IF NOT EXISTS idx_ctx_active_unique ON dim_context(context_name) WHERE is_active = true;

COMMENT ON TABLE dim_context IS 'Axis: where was this memory learned?';

-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS dim_tag (
    tag_key   SMALLINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    tag_name  VARCHAR(80) UNIQUE NOT NULL,       -- "security", "architecture-decision" ...
    parent_key INTEGER REFERENCES dim_tag(tag_key),  -- hierarchy: security > auth > jwt-patterns
    created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE dim_tag IS 'Axis: topic-based categorization with optional hierarchy';
COMMENT ON COLUMN dim_tag.parent_key IS 'Self-referencing for tag trees; NULL = root tag';


-- -----------------------------------------------------------
-- FACT TABLE (center of the star)
-- Every dimension is an integer FK - no string joins on hot path
-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_memories (
    id            SERIAL PRIMARY KEY,

    category_key  SMALLINT REFERENCES dim_category(category_key),
    context_key   SMALLINT REFERENCES dim_context(context_key),

    slug          VARCHAR(120) NOT NULL,              -- stable human-readable key (partial unique below ensures only one CURRENT per slug)
    title         VARCHAR(300) NOT NULL,               -- one-line summary
    body          TEXT NOT NULL,                       -- full memory content

    is_current    BOOLEAN DEFAULT true,                -- leaf node = current truth; false = superseded

    created_at    TIMESTAMPTZ DEFAULT NOW(),
    updated_at    TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE fact_memories IS 'The central table: every memory/fact/knowledge piece lives here';
COMMENT ON COLUMN fact_memories.is_current IS 'TRUE = current truth (leaf of succession chain). FALSE = superseded by newer evidence.';

-- Indexes for fast dimension-based lookups (integer seeks, not scans)
CREATE INDEX IF NOT EXISTS idx_fm_category   ON fact_memories(category_key);
CREATE INDEX IF NOT EXISTS idx_fm_context    ON fact_memories(context_key);

-- Partial index: only current facts. The hot path is "give me what's still true."
CREATE INDEX IF NOT EXISTS idx_fm_current_only ON fact_memories(id, slug, title) WHERE is_current = true;

-- Only one CURRENT memory per slug (allows superseded rows to reuse the same name)
CREATE UNIQUE INDEX IF NOT EXISTS idx_slug_current_unique ON fact_memories(slug) WHERE is_current = true;

-- Full-text search fallback for text queries against the huge table
CREATE INDEX IF NOT EXISTS idx_fm_fts ON fact_memories USING GIN (to_tsvector('english', title || ' ' || body));


-- -----------------------------------------------------------
-- BRIDGE TABLES (many-to-many relationships)
-- -----------------------------------------------------------

-- Tags: a memory can have multiple tags, resolved through small dim_tag first
CREATE TABLE IF NOT EXISTS fact_memory_tags (
    memory_id INTEGER REFERENCES fact_memories(id) ON DELETE CASCADE,
    tag_key   SMALLINT  REFERENCES dim_tag(tag_key),
    PRIMARY KEY (memory_id, tag_key)
);

COMMENT ON TABLE fact_memory_tags IS 'Bridge: memories are tagged with topics from dim_tag';

CREATE INDEX IF NOT EXISTS idx_fmt_tag_lookup ON fact_memory_tags(tag_key);

-- Contexts bridge: a memory learned in one project may be relevant to several
CREATE TABLE IF NOT EXISTS fact_memory_contexts_bridge (
    memory_id INTEGER REFERENCES fact_memories(id) ON DELETE CASCADE,
    context_key SMALLINT  REFERENCES dim_context(context_key),
    PRIMARY KEY (memory_id, context_key)
);

COMMENT ON TABLE fact_memory_contexts_bridge IS 'Bridge: additional contexts beyond the primary context_key on fact_memories';


-- -----------------------------------------------------------
-- SUCCESSION CHAIN (replaces confidence decay model)
-- Directed graph of how knowledge evolved over time
-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS fact_succession (
    id              SERIAL PRIMARY KEY,
    original_fact   INTEGER REFERENCES fact_memories(id) ON DELETE CASCADE,
    new_fact        INTEGER REFERENCES fact_memories(id) ON DELETE CASCADE,

    succession_type VARCHAR(30) NOT NULL DEFAULT 'supersedes',
       -- supersedes     = direct contradiction; the old fact is wrong
       -- refines        = more precise version of the same idea
       -- contextualizes = was right but incomplete; here is context

    evidence      TEXT,          -- why did we supersede? what changed? reasoning trail.
    recorded_at   TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE fact_succession IS 'Replaces confidence decay: facts are current or superseded by newer evidence';

CREATE INDEX IF NOT EXISTS idx_fs_original ON fact_succession(original_fact);
CREATE INDEX IF NOT EXISTS idx_fs_new      ON fact_succession(new_fact);


-- -----------------------------------------------------------
-- RECALL WEIGHTS (configurable scoring for associative recall)
-- Recall pulls from ALL contexts, scored by relevance signals.
-- Tuning these values changes behavior without rewriting queries.
-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS recall_weights (
    signal_name   VARCHAR(50) PRIMARY KEY,       -- "context_match", "tag_hit", ...
    weight_value  SMALLINT NOT NULL               -- +50, +30, -10...
);

INSERT INTO recall_weights (signal_name, weight_value) VALUES
    ('context_match',     50),   -- same project as current work? big bonus.
    ('tag_hit',          30),    -- tagged with the topic I'm asking about? per hit.
    ('recency_bonus',      20),  -- verified recently and still trustworthy.
    ('succession_penalty',  -10),   -- superseded but NOT excluded; old reasoning is evidence

-- Category priorities for session preload (higher = loaded first):
    ('category_user-identity',           100),  -- name, role, expertise level
    ('category_workflow-preferences',     80),  -- how user likes to work
    ('category_coding-style',             75),  -- coding conventions & taste
    ('category_user-understanding',       90),  -- organic observations about the user — opinions formed over time
    ('category_project-insights',         60),  -- judgments about projects, architecture, patterns noticed
    ('category_user-preferences',         70)   -- general personal preferences
ON CONFLICT (signal_name) DO UPDATE SET weight_value = EXCLUDED.weight_value;

COMMENT ON TABLE recall_weights IS 'Configurable scoring signals for associative (non-compartmentalized) recall';


-- -----------------------------------------------------------
-- VERIFICATION EVENTS (evidence-driven, not time-driven)
-- Only logged when actively confirmed or contradicted
-- A fact verified once and never questioned stays current indefinitely
-- -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS verification_events (
    id          SERIAL PRIMARY KEY,
    memory_id   INTEGER REFERENCES fact_memories(id) ON DELETE CASCADE,

    result      VARCHAR(20) NOT NULL CHECK (result IN ('confirmed', 'superseded')),
       -- confirmed  = still valid; no action needed on the chain
       -- superseded = triggers a new fact + succession entry

    source      VARCHAR(100),          -- "user said so" | "found in code" | "inferred from conversation pattern"
    recorded_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE verification_events IS 'Evidence-driven checks: no periodic decay, only active confirmation or contradiction';


-- -----------------------------------------------------------
-- HELPER VIEWS (for convenient querying)
-- -----------------------------------------------------------

-- View 1: All current memories with enriched dimension names and tags
CREATE OR REPLACE VIEW vw_current_memories AS
SELECT
    fm.id,
    fm.slug,
    fm.title,
    fm.body,
    fm.is_current,
    dc.category_name,
    dctx.context_name          AS primary_context,
    dt.tag_names               AS topics,
    ARRAY_AGG(DISTINCT fc.context_name) FILTER (WHERE fc.context_name IS NOT NULL AND fc.context_name <> dctx.context_name) AS additional_contexts,
    fm.created_at,
    fm.updated_at
FROM fact_memories fm
JOIN dim_category dc       ON fm.category_key = dc.category_key
JOIN dim_context  dctx     ON fm.context_key   = dctx.context_key

LEFT JOIN LATERAL (
    SELECT ARRAY_AGG(dt.tag_name) AS tag_names
    FROM fact_memory_tags ftag
    JOIN dim_tag dt ON ftag.tag_key = dt.tag_key
    WHERE ftag.memory_id = fm.id
) dt ON true

LEFT JOIN LATERAL (
    SELECT dctx2.context_name
    FROM fact_memory_contexts_bridge fcbr
    JOIN dim_context dctx2 ON fcbr.context_key = dctx2.context_key
    WHERE fcbr.memory_id = fm.id
) fc ON true

WHERE fm.is_current = true
GROUP BY fm.id, fm.slug, fm.title, fm.body, dc.category_name, dctx.context_name, dt.tag_names;


-- View 2: Succession chains (walk the reasoning trail for any fact)
CREATE OR REPLACE VIEW vw_succession_chains AS
SELECT
    fs.id          AS succession_id,
    old_mem.slug   AS original_slug,
    old_mem.title  AS original_title,
    new_mem.slug   AS superseding_slug,
    new_mem.title  AS superseding_title,
    fs.succession_type,
    fs.evidence,
    fs.recorded_at
FROM fact_succession fs
JOIN fact_memories old_mem ON fs.original_fact = old_mem.id
JOIN fact_memories new_mem ON fs.new_fact      = new_mem.id;

-- -----------------------------------------------------------
-- STORED FUNCTIONS (Interface Layer)
-- Callers never touch individual tables — they call these.
-- All operations are atomic within single transactions.
-- -----------------------------------------------------------

-- Function 1: Store a new memory with auto-resolution of dimensions
CREATE OR REPLACE FUNCTION fn_store_memory(
    p_slug        TEXT,
    p_category    TEXT,
    p_context     TEXT,
    p_title       TEXT,
    p_body        TEXT,
    p_tag_names   TEXT[] DEFAULT '{}'
) RETURNS INTEGER AS $$
DECLARE
    v_cat_key     SMALLINT;
    v_ctx_key     SMALLINT;
    v_fact_id     INTEGER;
    v_tag_name    TEXT;       -- iterator for the text array
    v_tk          SMALLINT;  -- resolved tag key after lookup/insert
BEGIN
    -- Resolve category (create if missing) — always SELECT afterward in case row already existed.
    INSERT INTO dim_category (category_name) VALUES (p_category)
    ON CONFLICT (category_name) DO NOTHING;
    SELECT category_key INTO v_cat_key FROM dim_category WHERE category_name = p_category;

    -- Resolve context (create if missing). Upsert pattern matches category table to prevent dimension bloat.
    INSERT INTO dim_context (context_name) VALUES (p_context)
    ON CONFLICT DO NOTHING;
    SELECT context_key INTO v_ctx_key FROM dim_context WHERE context_name = p_context AND is_active = true LIMIT 1;

    -- Guard: refuse duplicate slugs that are still current.
    IF EXISTS (SELECT 1 FROM fact_memories WHERE slug = p_slug AND is_current = true) THEN
        RAISE EXCEPTION 'A current memory with slug "%" already exists. Use fn_supersede_fact() instead.', p_slug;
    END IF;

    -- Insert the fact.
    INSERT INTO fact_memories (category_key, context_key, slug, title, body, is_current)
    VALUES (v_cat_key, v_ctx_key, p_slug, p_title, p_body, true)
    RETURNING id INTO v_fact_id;

    -- Tag bridge: resolve each tag name and insert.
    FOREACH v_tag_name IN ARRAY p_tag_names LOOP
        INSERT INTO dim_tag (tag_name) VALUES (v_tag_name)
        ON CONFLICT (tag_name) DO NOTHING;
        SELECT tag_key INTO v_tk FROM dim_tag WHERE tag_name = v_tag_name;

        INSERT INTO fact_memory_tags (memory_id, tag_key)
        VALUES (v_fact_id, v_tk)
        ON CONFLICT DO NOTHING;
    END LOOP;

    RETURN v_fact_id;
END;
$$ LANGUAGE plpgsql;


-- Function 2: Scored associative recall by topic
CREATE OR REPLACE FUNCTION fn_recall_by_topic(
    p_tag_pattern   TEXT DEFAULT '%',
    p_current_ctx   TEXT DEFAULT NULL
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
    v_pattern       TEXT;
BEGIN
    -- Load weights from config table (defaults above used if row missing).
    SELECT weight_value INTO w_tag_hit      FROM recall_weights WHERE signal_name = 'tag_hit';
    SELECT weight_value INTO w_ctx_match    FROM recall_weights WHERE signal_name = 'context_match';
    SELECT weight_value INTO w_recency      FROM recall_weights WHERE signal_name = 'recency_bonus';
    SELECT weight_value INTO w_succ_penalty FROM recall_weights WHERE signal_name = 'succession_penalty';

    -- Auto-wrap with wildcards if pattern contains no % or _ (substring match is almost always what's wanted).
    v_pattern := p_tag_pattern;
    IF POSITION('%' IN v_pattern) = 0 AND POSITION('_' IN v_pattern) = 0 THEN
        v_pattern := '%' || v_pattern || '%';
    END IF;

    -- Resolve current context if provided.
    IF p_current_ctx IS NOT NULL THEN
        SELECT context_key INTO v_ctx_key FROM dim_context WHERE context_name = p_current_ctx;
    END IF;

    RETURN QUERY
    WITH RECURSIVE matched_tags AS (
        -- Seed: tags whose names match the pattern directly.
        SELECT tag_key, parent_key FROM dim_tag WHERE tag_name ILIKE v_pattern

        UNION ALL

        -- Recurse down: children of any matched tag also count.
        SELECT child.tag_key, child.parent_key
        FROM dim_tag child
        JOIN matched_tags mt ON child.parent_key = mt.tag_key
    ),
    hit AS (
        -- Every fact that carries at least one matching tag — joined directly through the bridge.
        SELECT DISTINCT fm.id  AS fact_id,
               fm.slug::TEXT         AS slug,
               fm.title::TEXT       AS title,
               fm.body             AS body,
               fm.is_current   AS is_current,
               dc.category_name::VARCHAR(50)    AS category,
               dctx.context_name::TEXT          AS primary_context,

               -- Relevance score: sum of configurable signals.
               CASE WHEN NOT fm.is_current THEN w_succ_penalty ELSE 0 END
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
             AS base_score

        FROM fact_memories fm
        JOIN dim_category dc   ON fm.category_key = dc.category_key
        JOIN dim_context dctx  ON fm.context_key   = dctx.context_key
        JOIN fact_memory_tags ftag ON fm.id = ftag.memory_id
        JOIN matched_tags mt    ON ftag.tag_key = mt.tag_key
    ),
    ranked AS (
        SELECT h.*,
               -- Per-tag-hit bonus: how many matching tags does this fact carry?
               (w_tag_hit * (SELECT COUNT(*)::INTEGER FROM fact_memory_tags ft2
                            WHERE ft2.memory_id = h.fact_id
                              AND ft2.tag_key IN (SELECT tag_key FROM matched_tags))
             + h.base_score)::INTEGER AS relevance_score_final

        FROM hit h
    )
    SELECT r.fact_id, r.slug, r.title, r.body, r.is_current, r.category,
           r.relevance_score_final,
           r.primary_context,
           (SELECT ARRAY_AGG(dt.tag_name::TEXT ORDER BY dt.tag_name)
            FROM fact_memory_tags ft3 JOIN dim_tag dt ON ft3.tag_key = dt.tag_key
            WHERE ft3.memory_id = r.fact_id)

    FROM ranked r
    ORDER BY relevance_score_final DESC;

END;
$$ LANGUAGE plpgsql;


-- Function 3: Supersede an existing fact + create chain entry
CREATE OR REPLACE FUNCTION fn_supersede_fact(
    p_old_slug     TEXT,
    p_new_title    TEXT,
    p_new_body     TEXT DEFAULT NULL,
    p_evidence     TEXT DEFAULT NULL,
    p_succ_type    VARCHAR(30) DEFAULT 'supersedes'
) RETURNS INTEGER AS $$
DECLARE
    v_old_id      INTEGER;
    v_new_id      INTEGER;
BEGIN
    -- Find current fact by slug. If not found, search for an already-versioned successor (_v1 _v2...) that IS current.
    SELECT id INTO v_old_id FROM fact_memories WHERE slug = p_old_slug AND is_current = true;
    IF NOT FOUND THEN
        SELECT id INTO v_old_id FROM fact_memories WHERE slug LIKE p_old_slug || '_v%' AND is_current = true LIMIT 1;
    END IF;

    -- Still not found? Graceful fail — caller can handle without crashing mid-conversation.
    IF NOT FOUND THEN
        RAISE NOTICE 'fn_supersede_fact: no current memory found with slug "%" (it may have been superseded already)', p_old_slug;
        RETURN -1;  -- truly gone or wrong prefix passed in
    END IF;

    -- Mark old as superseded
    UPDATE fact_memories SET is_current = false, updated_at = NOW() WHERE id = v_old_id;

    -- Create new fact with versioned slug to preserve history. Fall back to old body if nothing provided — don't store blank memories.
    INSERT INTO fact_memories (category_key, context_key, slug, title, body, is_current)
    SELECT category_key, context_key, slug || '_v' ||
           (SELECT COUNT(*) FROM fact_memories WHERE slug LIKE p_old_slug || '%'),
           p_new_title, COALESCE(NULLIF(p_new_body, ''), body), true
    FROM fact_memories WHERE id = v_old_id
    RETURNING id INTO v_new_id;

    -- Insert succession chain entry
    INSERT INTO fact_succession (original_fact, new_fact, succession_type, evidence)
    VALUES (v_old_id, v_new_id, p_succ_type, p_evidence);

    -- Copy tags from old to new
    INSERT INTO fact_memory_tags (memory_id, tag_key)
    SELECT v_new_id, tag_key FROM fact_memory_tags WHERE memory_id = v_old_id
    ON CONFLICT DO NOTHING;

    RETURN v_new_id;
END;
$$ LANGUAGE plpgsql;


-- Function 4: Log a verification event (confirmation or contradiction)
-- Returns status code instead of RAISE EXCEPTION so silent background ops don't crash mid-conversation.
CREATE OR REPLACE FUNCTION fn_verify_fact(
    p_slug   TEXT,
    p_result VARCHAR(20),
    p_source TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
DECLARE
    v_mem_id INTEGER;
BEGIN
    -- Resolve slug to current fact (graceful: return -1 if not found instead of crashing)
    SELECT id INTO v_mem_id FROM fact_memories WHERE slug = p_slug AND is_current = true;
    IF NOT FOUND THEN
        RAISE NOTICE 'fn_verify_fact: no current memory found with slug "%".', p_slug;
        RETURN -1;  -- not found — caller can ignore silently for background verification
    END IF;

    INSERT INTO verification_events (memory_id, result, source)
    VALUES (v_mem_id, p_result, p_source);

    RETURN 0;  -- success
END;
$$ LANGUAGE plpgsql;


-- Function 5: Walk the reasoning trail for a slug prefix
-- Returns slug, succession_type, and evidence so caller can explain "why do you think that?" — not just list facts.
CREATE OR REPLACE FUNCTION fn_get_succession_chain(
    p_slug_prefix TEXT
) RETURNS TABLE (
    fact_id         INTEGER,
    slug            TEXT,              -- trace versioned slugs: my-decision_v1, _v2...
    title           TEXT,
    body            TEXT,
    is_current      BOOLEAN,
    succession_type VARCHAR(30),       -- supersedes | refines | contextualizes (NULL for original)
    evidence        TEXT,             -- the reasoning trail: why did it change?
    recorded_at     TIMESTAMPTZ
) AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT
        fm.id           AS fact_id,
        fm.slug::TEXT   AS slug,
        fm.title::TEXT  AS title,
        fm.body         AS body,
        fm.is_current   AS is_current,
        fs.succession_type::VARCHAR(30)  AS succession_type,
        fs.evidence     AS evidence,
        fm.created_at   AS recorded_at
    FROM fact_memories fm
    LEFT JOIN fact_succession fs ON (fm.id = fs.original_fact AND fs.succession_type IS NOT NULL)
                                OR (fm.id = fs.new_fact AND fs.succession_type IS NOT NULL)
    WHERE fm.slug LIKE p_slug_prefix || '%'
    ORDER BY fm.created_at ASC;
END;
$$ LANGUAGE plpgsql;


-- Function 6: Full-text deep search using GIN index on title + body
-- Separate from tag-based recall (fn_recall_by_topic). Triggered by "look harder" natural language cues.
CREATE OR REPLACE FUNCTION fn_recall_by_text(
    p_query       TEXT,
    p_current_ctx TEXT DEFAULT NULL
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
               (ts_rank(to_tsvector('english', fm.title || ' ' || fm.body), plainto_tsquery('english', p_query)) * 40)::INTEGER
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
        WHERE to_tsvector('english', fm.title || ' ' || fm.body) @@ plainto_tsquery('english', p_query)
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


-- Function 7: Mutation helper — add tags to an existing fact post-storage
CREATE OR REPLACE FUNCTION fn_add_tags(
    p_slug      TEXT,
    p_tag_names TEXT[] DEFAULT '{}'
) RETURNS VOID AS $$
DECLARE
    v_mem_id     INTEGER;
    v_tag_name   TEXT;
    v_tk         SMALLINT;
BEGIN
    -- Resolve slug to current fact (graceful: do nothing if not found instead of crashing).
    SELECT id INTO v_mem_id FROM fact_memories WHERE slug = p_slug AND is_current = true;
    IF NOT FOUND THEN
        RAISE NOTICE 'fn_add_tags: no current memory found with slug "%".', p_slug;
        RETURN;  -- silent fail — caller can ignore for background mutation attempts
    END IF;

    FOREACH v_tag_name IN ARRAY p_tag_names LOOP
        INSERT INTO dim_tag (tag_name) VALUES (v_tag_name)
        ON CONFLICT DO NOTHING;
        SELECT tag_key INTO v_tk FROM dim_tag WHERE tag_name = v_tag_name;

        INSERT INTO fact_memory_tags (memory_id, tag_key)
        VALUES (v_mem_id, v_tk)
        ON CONFLICT DO NOTHING;  -- idempotent: only adds missing tags; existing unchanged
    END LOOP;
END;
$$ LANGUAGE plpgsql;


-- Function 8: Mutation helper — attach secondary context via bridge table post-storage
CREATE OR REPLACE FUNCTION fn_add_context(
    p_slug         TEXT,
    p_context_name TEXT
) RETURNS VOID AS $$
DECLARE
    v_mem_id     INTEGER;
    v_ctx_key    SMALLINT;
BEGIN
    -- Resolve slug to current fact (graceful: do nothing if not found instead of crashing).
    SELECT id INTO v_mem_id FROM fact_memories WHERE slug = p_slug AND is_current = true;
    IF NOT FOUND THEN
        RAISE NOTICE 'fn_add_context: no current memory found with slug "%".', p_slug;
        RETURN;  -- silent fail — caller can ignore for background mutation attempts
    END IF;

    -- Resolve context (create if missing). Upsert pattern matches fn_store_memory.
    INSERT INTO dim_context (context_name) VALUES (p_context_name)
    ON CONFLICT DO NOTHING;
    SELECT context_key INTO v_ctx_key FROM dim_context WHERE context_name = p_context_name AND is_active = true LIMIT 1;

    -- Attach via bridge table (idempotent: only adds missing contexts).
    INSERT INTO fact_memory_contexts_bridge (memory_id, context_key)
    VALUES (v_mem_id, v_ctx_key)
    ON CONFLICT DO NOTHING;
END;
$$ LANGUAGE plpgsql;


-- Function 9: Session preload — top-N current memories for identity/context bootstrapping
-- Called at session start to pre-load user name, preferences, habits into model context.
-- Category priority weights (from recall_weights) boost identity facts above general knowledge.
CREATE OR REPLACE FUNCTION fn_session_preload(
    p_limit INTEGER DEFAULT 10
) RETURNS TABLE (
    slug            TEXT,
    title           TEXT,
    body            TEXT,
    category        VARCHAR(50),
    preload_score   INTEGER
) AS $$
BEGIN
    RETURN QUERY
    WITH scored AS (
        SELECT fm.slug::TEXT                           AS slug_out,
               fm.title::TEXT                          AS title_out,
               fm.body                                 AS body_out,
               dc.category_name::VARCHAR(50)            AS category_out,
               fm.created_at                            AS created_at_out,

               -- Base priority from category weight config (default 10 if no row).
               COALESCE((SELECT rw.weight_value FROM recall_weights rw
                         WHERE rw.signal_name = 'category_' || dc.category_name), 10)

                 + CASE WHEN EXISTS (
                        SELECT 1 FROM verification_events ve
                        WHERE ve.memory_id = fm.id
                          AND ve.recorded_at > NOW() - INTERVAL '90 days'
                          AND ve.result = 'confirmed'
                   ) THEN 20 ELSE 0 END   -- recency bonus

                 AS preload_score_final

        FROM fact_memories fm
        JOIN dim_category dc ON fm.category_key = dc.category_key
        WHERE fm.is_current = true
    )
    SELECT slug_out, title_out, body_out, category_out, preload_score_final
    FROM scored
    ORDER BY preload_score_final DESC, created_at_out ASC   -- identity first; oldest within same tier.
    LIMIT p_limit;

END;
$$ LANGUAGE plpgsql;


COMMIT;

-- Record this version as applied (outside transaction for safety)
INSERT INTO ltm_initialized (schema_version) VALUES (1) ON CONFLICT DO NOTHING;