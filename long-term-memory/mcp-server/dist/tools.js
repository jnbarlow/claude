// ─── Tool definitions (single source of truth) ──────────────────────
// Every LTM tool is declared here as a { name, schema, handler } tuple. Both
// transports consume the SAME definitions:
//   - registerOnServer()  → registers each on an McpServer (stdio transport)
//   - serveHttp()         → routes /api/tool requests through the handlers
// Keeping them in one module means stdio and HTTP can never drift apart, and
// the HTTP daemon doesn't need to import the stdio server.
import z from "zod";
import { getConnectionString, withClient } from "./db.js";
import { incrementDailyStoreCount } from "./store-counter.js";
// Per-process dedup of slugs injected this session. Lives in whichever process
// runs the tool (stdio server OR HTTP daemon) — intentionally NOT shared across
// processes, since two processes are two separate conversations and it's fine for
// a fact to be re-injected depending on context. See ltm-mcp-server-architecture.
const injectedSlugs = new Set();
function filterInjectedResults(rows, slugField = "slug") {
    const filtered = [];
    let allFiltered = true;
    for (const row of rows) {
        const slug = row[slugField];
        if (!injectedSlugs.has(slug)) {
            injectedSlugs.add(slug);
            filtered.push(row);
            allFiltered = false;
        }
    }
    return { filteredRows: filtered, allFiltered };
}
const notConfigured = () => ({ content: [{ type: "text", text: "🧠 LTM not configured." }] });
function fmt(text) {
    return { content: [{ type: "text", text }] };
}
// Build the tool-definition list. Each entry carries its Zod schema so both
// transports expose identical input contracts.
export function buildToolDefinitions() {
    const defs = [];
    // ─── ltm_store_memory ──────────────────────────────────────────────
    defs.push({
        name: "ltm_store_memory",
        schema: { slug: z.string(), category: z.string(), context: z.string(), title: z.string(), body: z.string(), tags: z.array(z.string()).optional() },
        handler: async ({ slug, category, context, title, body, tags }) => {
            if (!getConnectionString())
                return notConfigured();
            const tag_names = Array.isArray(tags) ? tags : [];
            const result = await withClient(async (client) => client.query(`SELECT fn_store_memory($1, $2, $3, $4, $5, $6::text[])`, [slug, category, context, title, body, tag_names]));
            if (!result.ok)
                return fmt("❌ Failed to store memory.");
            const fact_id = result.data?.rows[0]?.fn_store_memory;
            incrementDailyStoreCount();
            return fmt(`🧠 Stored (fact_id=${fact_id}) ✓`);
        },
    });
    // ─── ltm_recall_by_topic ───────────────────────────────────────────
    defs.push({
        name: "ltm_recall_by_topic",
        schema: { tag_pattern: z.string(), current_context: z.string().optional(), min_score: z.number().optional() },
        handler: async ({ tag_pattern, current_context, min_score }) => {
            if (!getConnectionString())
                return notConfigured();
            let result;
            if (current_context) {
                result = await withClient(async (client) => client.query(`SELECT slug, title, body, is_current, relevance_score FROM fn_recall_by_topic($1, $2)`, [tag_pattern, current_context]));
            }
            else {
                result = await withClient(async (client) => client.query(`SELECT slug, title, body, is_current, relevance_score FROM fn_recall_by_topic($1)`, [tag_pattern]));
            }
            if (!result.ok || !result.data?.rows.length)
                return fmt("🧠 No matching memories.");
            let rows = result.data.rows;
            if (min_score && rows.length > 0) {
                rows = rows.filter(r => r.relevance_score >= min_score);
                if (rows.length === 0)
                    return fmt(`🧠 No matching memories above score threshold (${min_score}).`);
            }
            let output = `Found ${rows.length} memory(ies):\n`;
            for (const r of rows) {
                const status = r.is_current ? "(current)" : "[superseded]";
                output += `\n  • [${status}] ${r.title}`;
                output += `\n    Slug: ${r.slug} | Score: ${r.relevance_score}`;
                if (typeof r.body === "string" && r.body.length > 120) {
                    output += `\n    Body: ${r.body.slice(0, 120)}…`;
                }
                else {
                    output += `\n    Body: ${r.body || ""}`;
                }
            }
            return fmt(output);
        },
    });
    // ─── ltm_recall_by_text ────────────────────────────────────────────
    defs.push({
        name: "ltm_recall_by_text",
        schema: { query: z.string(), current_context: z.string().optional(), min_score: z.number().optional() },
        handler: async ({ query, deduplicate, current_context, min_score }) => {
            if (!getConnectionString())
                return notConfigured();
            let result;
            if (current_context) {
                result = await withClient(async (client) => client.query(`SELECT slug, title, body, is_current, relevance_score FROM fn_recall_by_text($1, $2)`, [query, current_context]));
            }
            else {
                result = await withClient(async (client) => client.query(`SELECT slug, title, body, is_current, relevance_score FROM fn_recall_by_text($1)`, [query]));
            }
            if (!result.ok || !result.data?.rows.length)
                return fmt("🧠 No matching memories.");
            let rows = result.data.rows;
            if (deduplicate) {
                const { filteredRows, allFiltered } = filterInjectedResults(rows);
                if (allFiltered)
                    return fmt(""); // Empty = already injected.
                rows = filteredRows;
            }
            if (min_score && rows.length > 0) {
                rows = rows.filter(r => r.relevance_score >= min_score);
                if (rows.length === 0)
                    return fmt(`🧠 No matching memories above score threshold (${min_score}).`);
            }
            let output = `Found ${rows.length} memory(ies):\n`;
            for (const r of rows) {
                const status = r.is_current ? "(current)" : "[superseded]";
                output += `\n  • [${status}] ${r.title}`;
                output += `\n    Slug: ${r.slug} | Score: ${r.relevance_score}`;
                if (typeof r.body === "string" && r.body.length > 120) {
                    output += `\n    Body: ${r.body.slice(0, 120)}…`;
                }
                else {
                    output += `\n    Body: ${r.body || ""}`;
                }
            }
            return fmt(output);
        },
    });
    // ─── ltm_supersede_fact ────────────────────────────────────────────
    defs.push({
        name: "ltm_supersede_fact",
        schema: { slug: z.string(), new_title: z.string() },
        handler: async ({ slug, new_title }) => {
            if (!getConnectionString())
                return notConfigured();
            const result = await withClient(async (client) => client.query(`SELECT fn_supersede_fact($1, $2)`, [slug, new_title]));
            if (!result.ok || !result.data?.rows.length)
                return fmt("❌ Failed to supersede.");
            const factVal = result.data.rows[0]?.fn_supersede_fact;
            if (factVal === -1)
                return fmt(`⚠️ Slug "${slug}" not found — nothing to supersede.`);
            return fmt(`🔄 Superseded (new_id=${factVal}) ✓`);
        },
    });
    // ─── ltm_verify_fact ───────────────────────────────────────────────
    defs.push({
        name: "ltm_verify_fact",
        schema: { slug: z.string(), result_val: z.string() },
        handler: async ({ slug, result_val }) => {
            if (!getConnectionString())
                return notConfigured();
            const verify_result = await withClient(async (client) => client.query(`SELECT fn_verify_fact($1, $2)`, [slug, result_val]));
            if (!verify_result.ok || !verify_result.data?.rows.length)
                return fmt("❌ Verification failed.");
            const code = verify_result.data.rows[0]?.fn_verify_fact;
            if (code === -1)
                return fmt(`⚠️ Slug "${slug}" not found — nothing to verify.`);
            return fmt(`✓ Verified ${slug} (${result_val})`);
        },
    });
    // ─── ltm_add_tags ──────────────────────────────────────────────────
    defs.push({
        name: "ltm_add_tags",
        schema: { slug: z.string(), tags: z.array(z.string()).optional() },
        handler: async ({ slug, tags }) => {
            if (!getConnectionString())
                return notConfigured();
            const tag_names = Array.isArray(tags) ? tags : [];
            const result = await withClient(async (client) => client.query(`SELECT fn_add_tags($1, $2::text[])`, [slug, tag_names]));
            if (!result.ok)
                return fmt("❌ Failed to add tags.");
            return fmt(`🏷️ Tags added for "${slug}" ✓`);
        },
    });
    // ─── ltm_add_context ───────────────────────────────────────────────
    defs.push({
        name: "ltm_add_context",
        schema: { slug: z.string(), context_name: z.string() },
        handler: async ({ slug, context_name }) => {
            if (!getConnectionString())
                return notConfigured();
            const result = await withClient(async (client) => client.query(`SELECT fn_add_context($1, $2)`, [slug, context_name]));
            if (!result.ok)
                return fmt("❌ Failed to add context.");
            return fmt(`📁 Context "${context_name}" added for "${slug}" ✓`);
        },
    });
    // ─── ltm_get_succession_chain ──────────────────────────────────────
    defs.push({
        name: "ltm_get_succession_chain",
        schema: { slug_prefix: z.string() },
        handler: async ({ slug_prefix }) => {
            if (!getConnectionString())
                return notConfigured();
            const result = await withClient(async (client) => client.query(`SELECT fact_id, slug, title, body, is_current FROM fn_get_succession_chain($1)`, [slug_prefix]));
            if (!result.ok || !result.data?.rows.length)
                return fmt("🧠 No succession history.");
            const rows = result.data.rows;
            let output = `Succession chain for "${slug_prefix}":\n`;
            for (const r of rows) {
                const status = r.is_current ? "(current)" : "[superseded]";
                output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
                if (typeof r.body === "string" && r.body.length > 120) {
                    output += `\n    Body: ${r.body.slice(0, 120)}…`;
                }
                else {
                    output += `\n    Body: ${r.body || ""}`;
                }
            }
            return fmt(output);
        },
    });
    // ─── ltm_session_preload ───────────────────────────────────────────
    defs.push({
        name: "ltm_session_preload",
        schema: { limit: z.number().optional() },
        handler: async ({ limit }) => {
            if (!getConnectionString())
                return notConfigured();
            const p_limit = Math.min(limit ?? 10, 20); // cap at 20 to avoid context bloat.
            const result = await withClient(async (client) => client.query(`SELECT slug, title, body, category, preload_score FROM fn_session_preload($1)`, [p_limit]));
            if (!result.ok || !result.data?.rows.length)
                return fmt("🧠 No memories to preload.");
            const rows = result.data.rows;
            let output = `🧠 Session Preload (${rows.length} memory):\n`;
            for (const r of rows) {
                output += `\n  • ${r.title}`;
                if (typeof r.body === "string" && r.body.length > 150) {
                    output += `\n    ${r.body.slice(0, 150)}…`;
                }
                else {
                    output += `\n    ${r.body || ""}`;
                }
                output += ` [${r.category}] (score: ${r.preload_score})`;
            }
            return fmt(output);
        },
    });
    // ─── ltm_list_memories ─────────────────────────────────────────────
    defs.push({
        name: "ltm_list_memories",
        schema: { limit: z.number().optional() },
        handler: async ({ limit }) => {
            if (!getConnectionString())
                return notConfigured();
            const p_limit = Math.min(Math.max(limit ?? 200, 1), 500); // clamp to [1, 500].
            const result = await withClient(async (client) => client.query(`SELECT fact_id, slug, title, body, is_current, category, primary_context, tags FROM fn_list_memories($1)`, [p_limit]));
            if (!result.ok || !result.data?.rows.length)
                return fmt("🧠 No memories found.");
            const rows = result.data.rows;
            let output = `📋 Listed ${rows.length} memory(ies):\n`;
            for (const r of rows) {
                const status = r.is_current ? "(current)" : "[superseded]";
                output += `\n  • [${status}] ${r.title}`;
                output += `\n    Slug: ${r.slug} | Category: ${r.category}`;
                if (r.primary_context)
                    output += ` | Context: ${r.primary_context}`;
                if (typeof r.body === "string" && r.body.length > 150) {
                    output += `\n    Body: ${r.body.slice(0, 150)}…`;
                }
                else {
                    output += `\n    Body: ${r.body || ""}`;
                }
                if (Array.isArray(r.tags) && r.tags.length > 0) {
                    output += `\n    Tags: ${r.tags.join(", ")}`;
                }
            }
            return fmt(output);
        },
    });
    // ─── ltm_delete_fact ───────────────────────────────────────────────
    defs.push({
        name: "ltm_delete_fact",
        schema: { slug: z.string() },
        handler: async ({ slug }) => {
            if (!getConnectionString())
                return notConfigured();
            const result = await withClient(async (client) => client.query(`SELECT fn_delete_fact($1)`, [slug]));
            if (!result.ok || !result.data?.rows.length)
                return fmt("❌ Failed to delete.");
            const factVal = result.data.rows[0]?.fn_delete_fact;
            if (factVal === -1)
                return fmt(`⚠️ Slug "${slug}" not found — nothing to delete.`);
            return fmt(`🗑️ Deleted memory "${slug}" (id=${factVal}) ✓`);
        },
    });
    return defs;
}
// Register every tool on an McpServer (stdio transport). Called by index.ts.
export function registerOnServer(server, defs) {
    for (const def of defs) {
        server.tool(def.name, def.schema, def.handler);
    }
}
