-- LTM Schema migration v1 -> v2
-- Widen VARCHAR columns that are too small for real-world usage.
-- Must drop dependent views first (PostgreSQL blocks ALTER on referenced columns), then recreate them.

BEGIN;

/* --- Drop views depending on altered columns -------------------------------- */

DROP VIEW IF EXISTS vw_current_memories;
DROP VIEW IF EXISTS vw_succession_chains;

/* --- Widen columns --------------------------------------------------------- */

ALTER TABLE dim_context
    ALTER COLUMN context_name TYPE VARCHAR(512);

ALTER TABLE fact_memories
    ALTER COLUMN slug         TYPE VARCHAR(300),
    ALTER COLUMN title        TYPE VARCHAR(500);

/* --- Recreate views with widened column types -------------------------------- */

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

COMMIT;
