import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Pool } from "pg";
import * as fs from "fs";
import * as path from "path";
import z from "zod";
// ─── Configuration ──────────────────────────────────────────────
const CONNECTION_STRING = process.env.CLAUDE_PLUGIN_OPTION_LTM_DB;
if (!CONNECTION_STRING) {
    console.error("[ltm-mcp] Missing CLAUDE_PLUGIN_OPTION_LTM_DB — plugin not configured");
}
// Path to the SQL schema file (resolved from CLAUDE_PLUGIN_ROOT at runtime).
const SCHEMA_SQL = (() => {
    const root = process.env.CLAUDE_PLUGIN_ROOT;
    if (!root)
        return null;
    const candidate = path.join(root, "sql", "schema.sql");
    try {
        fs.accessSync(candidate);
        return candidate;
    }
    catch {
        return null;
    }
})();
// Read schema once at startup (idempotent DDL — safe to re-run).
let SCHEMA_CONTENT = null;
if (SCHEMA_SQL) {
    try {
        SCHEMA_CONTENT = fs.readFileSync(SCHEMA_SQL, "utf8");
    }
    catch {
        console.error("[ltm-mcp] Could not read schema.sql — will skip initialization.");
    }
}
// ─── Connection pool (lazy-init on first tool call or bootstrap) ──
let pool = null;
async function getPool() {
    const connStr = process.env.CLAUDE_PLUGIN_OPTION_LTM_DB || CONNECTION_STRING;
    if (!pool) {
        pool = new Pool({ connectionString: connStr });
    }
    else if (connStr !== CONNECTION_STRING) {
        // Rebuild only if the env var actually changed at runtime.
        await pool.end();
        pool = null;
        pool = new Pool({ connectionString: connStr });
    }
    return pool;
}
async function withClient(fn) {
    if (!CONNECTION_STRING) {
        return { ok: false }; // handled by bootstrap diagnostic instead of crashing mid-tool-call.
    }
    const p = await getPool();
    const client = await p.connect();
    try {
        const result = await fn(client);
        return { ok: true, data: result };
    }
    catch (err) {
        console.error("[ltm-mcp] query error:", err instanceof Error ? err.message : String(err));
        return { ok: false };
    }
    finally {
        client.release();
    }
}
// ─── Bootstrap logic ──────────────────────────────────────────────
async function bootstrap() {
    if (!CONNECTION_STRING) {
        console.error("[ltm-mcp] LTM not configured — no connection string.");
        return { connected: false, message: "🧠 LTM: Long-term memory is not configured." };
    }
    try {
        const client = await new Pool({ connectionString: CONNECTION_STRING }).connect();
        // Test connectivity.
        await client.query("SELECT 1");
        // Check if schema has been applied by querying the marker table.
        let needsInit = true;
        try {
            const check = await client.query("SELECT COALESCE(MAX(schema_version), 0) AS ver FROM ltm_initialized");
            const currentVer = parseInt(check.rows[0]?.ver, 10);
            if (currentVer > 0) {
                console.log(`[ltm-mcp] Schema already applied (v${currentVer}).`);
                needsInit = false;
            }
            else {
                console.log("[ltm-mcp] No schema marker found — will apply DDL.");
            }
        }
        catch {
            // Table doesn't exist yet — fresh DB.
            console.log("[ltm-mcp] Marker table missing — fresh database detected.");
        }
        if (needsInit && SCHEMA_CONTENT) {
            await client.query(SCHEMA_CONTENT);
            console.log("[ltm-mcp] Schema applied successfully.");
        }
        else if (needsInit && !SCHEMA_CONTENT) {
            console.error("[ltm-mcp] WARNING: Schema needs applying but schema.sql could not be read.");
        }
        client.release();
        console.log("[ltm-mcp] Connected to PostgreSQL.");
        return { connected: true };
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[ltm-mcp] Database unreachable — ${msg}`);
        return { connected: false, message: `🧠 LTM: Database unreachable at configured address.` };
    }
}
// ─── MCP Server Setup ──────────────────────────────────────────────
const server = new McpServer({ name: "ltm-postgres", version: "1.0.0" });
server.tool("ltm_store_memory", { slug: z.string(), category: z.string(), context: z.string(), title: z.string(), body: z.string(), tags: z.array(z.string()).optional() }, async ({ slug, category, context, title, body, tags }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const tag_names = Array.isArray(tags) ? tags : [];
    const result = await withClient(async (client) => {
        return client.query(`SELECT fn_store_memory($1, $2, $3, $4, $5, $6::text[])`, [slug, category, context, title, body, tag_names]);
    });
    if (!result.ok)
        return { content: [{ type: "text", text: "❌ Failed to store memory." }] };
    const fact_id = result.data?.rows[0]?.fn_store_memory;
    return { content: [{ type: "text", text: `🧠 Stored (fact_id=${fact_id}) ✓` }] };
});
server.tool("ltm_recall_by_topic", { tag_pattern: z.string() }, async ({ tag_pattern }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const result = await withClient(async (client) => {
        return client.query(`SELECT slug, title, body, is_current FROM fn_recall_by_topic($1)`, [tag_pattern]);
    });
    if (!result.ok || !result.data?.rows.length) {
        return { content: [{ type: "text", text: "🧠 No matching memories." }] };
    }
    const rows = result.data.rows;
    let output = `Found ${rows.length} memory(ies):\n`;
    for (const r of rows) {
        const status = r.is_current ? "(current)" : "[superseded]";
        output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
        if ((typeof r.body === "string" && r.body.length > 120)) {
            output += `\n    Body: ${r.body.slice(0, 120)}…`;
        }
        else {
            output += `\n    Body: ${r.body || ""}`;
        }
    }
    return { content: [{ type: "text", text: output }] };
});
server.tool("ltm_recall_by_text", { query: z.string() }, async ({ query }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const result = await withClient(async (client) => {
        return client.query(`SELECT slug, title, body, is_current FROM fn_recall_by_text($1)`, [query]);
    });
    if (!result.ok || !result.data?.rows.length) {
        return { content: [{ type: "text", text: "🧠 No matching memories." }] };
    }
    const rows = result.data.rows;
    let output = `Found ${rows.length} memory(ies):\n`;
    for (const r of rows) {
        const status = r.is_current ? "(current)" : "[superseded]";
        output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
        if ((typeof r.body === "string" && r.body.length > 120)) {
            output += `\n    Body: ${r.body.slice(0, 120)}…`;
        }
        else {
            output += `\n    Body: ${r.body || ""}`;
        }
    }
    return { content: [{ type: "text", text: output }] };
});
server.tool("ltm_supersede_fact", { slug: z.string(), new_title: z.string() }, async ({ slug, new_title }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const result = await withClient(async (client) => {
        return client.query(`SELECT fn_supersede_fact($1, $2)`, [slug, new_title]);
    });
    if (!result.ok || !result.data?.rows.length) {
        return { content: [{ type: "text", text: "❌ Failed to supersede." }] };
    }
    const factVal = result.data.rows[0]?.fn_supersede_fact;
    if (factVal === -1) {
        return { content: [{ type: "text", text: `⚠️ Slug "${slug}" not found — nothing to supersede.` }] };
    }
    return { content: [{ type: "text", text: `🔄 Superseded (new_id=${factVal}) ✓` }] };
});
server.tool("ltm_verify_fact", { slug: z.string(), result_val: z.string() }, async ({ slug, result_val }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const verify_result = await withClient(async (client) => {
        return client.query(`SELECT fn_verify_fact($1, $2)`, [slug, result_val]);
    });
    if (!verify_result.ok || !verify_result.data?.rows.length) {
        return { content: [{ type: "text", text: "❌ Verification failed." }] };
    }
    const code = verify_result.data.rows[0]?.fn_verify_fact;
    if (code === -1) {
        return { content: [{ type: "text", text: `⚠️ Slug "${slug}" not found — nothing to verify.` }] };
    }
    return { content: [{ type: "text", text: `✓ Verified ${slug} (${result_val})` }] };
});
server.tool("ltm_add_tags", { slug: z.string(), tags: z.array(z.string()).optional() }, async ({ slug, tags }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const tag_names = Array.isArray(tags) ? tags : [];
    const result = await withClient(async (client) => {
        return client.query(`SELECT fn_add_tags($1, $2::text[])`, [slug, tag_names]);
    });
    if (!result.ok) {
        return { content: [{ type: "text", text: "❌ Failed to add tags." }] };
    }
    // fn_add_tags returns VOID — success is indicated by no error.
    return { content: [{ type: "text", text: `🏷️ Tags added for "${slug}" ✓` }] };
});
server.tool("ltm_add_context", { slug: z.string(), context_name: z.string() }, async ({ slug, context_name }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const result = await withClient(async (client) => {
        return client.query(`SELECT fn_add_context($1, $2)`, [slug, context_name]);
    });
    if (!result.ok) {
        return { content: [{ type: "text", text: "❌ Failed to add context." }] };
    }
    // fn_add_context returns VOID — success is indicated by no error.
    return { content: [{ type: "text", text: `📁 Context "${context_name}" added for "${slug}" ✓` }] };
});
server.tool("ltm_get_succession_chain", { slug_prefix: z.string() }, // optional fields.
async ({ slug_prefix }) => {
    if (!CONNECTION_STRING)
        return { content: [{ type: "text", text: "🧠 LTM not configured." }] };
    const result = await withClient(async (client) => {
        return client.query(`SELECT fact_id, slug, title, body, is_current FROM fn_get_succession_chain($1)`, [slug_prefix]);
    });
    if (!result.ok || !result.data?.rows.length) {
        return { content: [{ type: "text", text: "🧠 No succession history." }] };
    }
    const rows = result.data.rows;
    let output = `Succession chain for "${slug_prefix}":\n`;
    for (const r of rows) {
        const status = r.is_current ? "(current)" : "[superseded]";
        output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
        if ((typeof r.body === "string" && r.body.length > 120)) {
            output += `\n    Body: ${r.body.slice(0, 120)}…`;
        }
        else {
            output += `\n    Body: ${r.body || ""}`;
        }
    }
    return { content: [{ type: "text", text: output }] };
});
// ─── Start server on stdio transport (no network port) ──────────────
async function main() {
    // Bootstrap connectivity test.
    const bs = await bootstrap();
    if (!bs.connected && !CONNECTION_STRING) {
        console.error(bs.message || "🧠 LTM: not configured.");
    }
    else if (bs.connected) {
        console.log("[ltm-mcp] Ready on stdio transport.");
    }
    const transport = new StdioServerTransport();
    await server.connect(transport);
}
main().catch((err) => {
    console.error(`[ltm-mcp] Fatal: ${err.message}`);
});
