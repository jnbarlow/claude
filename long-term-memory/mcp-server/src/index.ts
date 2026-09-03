import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { Pool, PoolClient } from "pg";
import * as fs from "fs";
import * as path from "path";
import * as http from "http";
import z from "zod";
import { resolveConnectionString } from "./secret.js";

// ─── Types ──────────────────────────────────────────────────────

interface McpContent {
  type: "text";
  text: string;
}

type McpResult = { content: McpContent[] };

// ─── Configuration ──────────────────────────────────────────────

let CONNECTION_STRING: string | null = null;
const PROVIDER = process.env.LTM_PROVIDER || "keychain";

// HTTP transport configuration (optional — disabled if LTM_HTTP_PORT is empty).
const HTTP_PORT = parseInt(process.env.LTM_HTTP_PORT || "58600", 10);
const HTTP_DISCOVERY_FILE = path.join(
  process.env.CLAUDE_PLUGIN_DATA || "/tmp",
  "ltm-mcp-port.txt"
);

// Detect old-style plaintext config (user pasted connection string into provider field).
if (PROVIDER.startsWith("postgresql://") || PROVIDER.startsWith("postgres://")) {
  console.error(
    "[ltm-mcp] DEPRECATED: It looks like you put a PostgreSQL connection string in the LTM_PROVIDER setting." +
      "\n   The plugin no longer stores credentials as plaintext. Please:" +
      "\n   1. Store your connection string in your chosen provider under 'LTM-DB' (see README for commands)" +
      "\n   2. Set LTM_PROVIDER to: aws, 1password, or keychain" +
      "\n   Or export LTM_DB_URL as an environment variable for local development."
  );
}

async function initConnection(): Promise<boolean> {
  CONNECTION_STRING = await resolveConnectionString(PROVIDER);
  if (!CONNECTION_STRING) {
    console.error("[ltm-mcp] Missing connection string — could not resolve from provider.");
    return false;
  }
  return true;
}

// Path to the SQL schema file (resolved from CLAUDE_PLUGIN_ROOT at runtime).
const SCHEMA_SQL = (() => {
  const root = process.env.CLAUDE_PLUGIN_ROOT;
  if (!root) return null;
  const candidate = path.join(root, "sql", "schema.sql");
  try {
    fs.accessSync(candidate);
    return candidate;
  } catch {
    return null;
  }
})();

// Read schema once at startup (idempotent DDL — safe to re-run).
let SCHEMA_CONTENT: string | null = null;
if (SCHEMA_SQL) {
  try {
    SCHEMA_CONTENT = fs.readFileSync(SCHEMA_SQL, "utf8");
  } catch {
    console.error("[ltm-mcp] Could not read schema.sql — will skip initialization.");
  }
}


// ─── Connection pool (lazy-init on first tool call or bootstrap) ──

let pool: Pool | null = null;

async function getPool(): Promise<Pool> {
  if (!CONNECTION_STRING) {
    throw new Error("Connection string not initialized — initConnection() was not called.");
  }
  if (!pool) {
    pool = new Pool({ connectionString: CONNECTION_STRING });
  }
  return pool;
}

async function withClient<T>(fn: (client: PoolClient) => Promise<T>): Promise<{ ok: boolean; data?: T }> {
  if (!CONNECTION_STRING) {
    return { ok: false }; // handled by bootstrap diagnostic instead of crashing mid-tool-call.
  }
  const p = await getPool();
  const client = await p.connect();
  try {
    const result = await fn(client);
    return { ok: true, data: result };
  } catch (err) {
    console.error("[ltm-mcp] query error:", err instanceof Error ? err.message : String(err));
    return { ok: false };
  } finally {
    client.release();
  }
}

// ─── Bootstrap logic ──────────────────────────────────────────────

async function bootstrap(): Promise<{ connected: boolean; message?: string }> {
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
      const check = await client.query(
        "SELECT COALESCE(MAX(schema_version), 0) AS ver FROM ltm_initialized"
      );
      const currentVer = parseInt(check.rows[0]?.ver, 10);
      if (currentVer > 0) {
        console.log(`[ltm-mcp] Schema already applied (v${currentVer}).`);
        needsInit = false;
      } else {
        console.log("[ltm-mcp] No schema marker found — will apply DDL.");
      }
    } catch {
      // Table doesn't exist yet — fresh DB.
      console.log("[ltm-mcp] Marker table missing — fresh database detected.");
    }

    if (needsInit && SCHEMA_CONTENT) {
      await client.query(SCHEMA_CONTENT);
      console.log("[ltm-mcp] Schema applied successfully.");
    } else if (needsInit && !SCHEMA_CONTENT) {
      console.error(
        "[ltm-mcp] WARNING: Schema needs applying but schema.sql could not be read."
      );
    }

    client.release();
    console.log("[ltm-mcp] Connected to PostgreSQL.");
    return { connected: true };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[ltm-mcp] Database unreachable — ${msg}`);
    return { connected: false, message: `🧠 LTM: Database unreachable at configured address.` };
  }
}

// ─── MCP Server Setup ──────────────────────────────────────────────

const server = new McpServer({ name: "ltm-postgres", version: "1.1.0" });

// Tool handler map — used by both MCP and HTTP transports.
const TOOL_HANDLERS: Record<string, (params: Record<string, any>) => Promise<McpResult>> = {};

function registerHandler(name: string, handler: typeof TOOL_HANDLERS[string]) {
  TOOL_HANDLERS[name] = handler;
}

// ─── In-memory deduplication for UserPromptSubmit hook ──────────────
// Tracks slugs that have been injected this "session" (MCP server lifetime).
// Prevents redundant context injection across multiple prompts.
const injectedSlugs = new Set<string>();

/**
 * Filter out already-injected slugs from LTM results.
 * Returns filtered rows and marks non-filtered slugs as injected.
 */
function filterInjectedResults(rows: any[], slugField: string = "slug"): { filteredRows: any[]; allFiltered: boolean } {
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

// Helper to check if a slug is already injected (used by hooks).
function isSlugInjected(slug: string): boolean {
  return injectedSlugs.has(slug);
}

const handleStoreMemory = async ({ slug, category, context, title, body, tags }: any): Promise<McpResult> => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const tag_names = Array.isArray(tags) ? (tags as string[]) : [];

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT fn_store_memory($1, $2, $3, $4, $5, $6::text[])`,
      [slug, category, context, title, body, tag_names]
    );
  });

  if (!result.ok) return { content: [{ type: "text" as const, text: "❌ Failed to store memory." }] };
  const fact_id = result.data?.rows[0]?.fn_store_memory;
  return { content: [{ type: "text" as const, text: `🧠 Stored (fact_id=${fact_id}) ✓` }] };
};

server.tool(
  "ltm_store_memory",
  { slug: z.string(), category: z.string(), context: z.string(), title: z.string(), body: z.string(), tags: z.array(z.string()).optional() },
  handleStoreMemory
);
registerHandler("ltm_store_memory", handleStoreMemory);

const handleRecallByTopic = async ({ tag_pattern }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT slug, title, body, is_current FROM fn_recall_by_topic($1)`,
      [tag_pattern]
    );
  });

  if (!result.ok || !result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "🧠 No matching memories." }] };
  }

  const rows = result.data.rows;
  let output = `Found ${rows.length} memory(ies):\n`;
  for (const r of rows) {
    const status = r.is_current ? "(current)" : "[superseded]";
    output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
    if ((typeof r.body === "string" && r.body.length > 120)) {
      output += `\n    Body: ${r.body.slice(0, 120)}…`;
    } else {
      output += `\n    Body: ${r.body || ""}`;
    }
  }

  return { content: [{ type: "text" as const, text: output }] };
};

server.tool(
  "ltm_recall_by_topic",
  { tag_pattern: z.string() },
  handleRecallByTopic
);
registerHandler("ltm_recall_by_topic", handleRecallByTopic);

const handleRecallByText = async ({ query, deduplicate }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT slug, title, body, is_current FROM fn_recall_by_text($1)`,
      [query]
    );
  });

  if (!result.ok || !result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "🧠 No matching memories." }] };
  }

  // Apply deduplication filter if requested.
  let rows = result.data.rows;
  if (deduplicate) {
    const { filteredRows, allFiltered } = filterInjectedResults(rows);
    if (allFiltered) {
      return { content: [{ type: "text" as const, text: "" }] }; // Empty = already injected.
    }
    rows = filteredRows;
  }

  let output = `Found ${rows.length} memory(ies):\n`;
  for (const r of rows) {
    const status = r.is_current ? "(current)" : "[superseded]";
    output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
    if ((typeof r.body === "string" && r.body.length > 120)) {
      output += `\n    Body: ${r.body.slice(0, 120)}…`;
    } else {
      output += `\n    Body: ${r.body || ""}`;
    }
  }

  return { content: [{ type: "text" as const, text: output }] };
};

server.tool(
  "ltm_recall_by_text",
  { query: z.string() },
  handleRecallByText
);
registerHandler("ltm_recall_by_text", handleRecallByText);

const handleSupersedeFact = async ({ slug, new_title }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT fn_supersede_fact($1, $2)`,
      [slug, new_title]
    );
  });

  if (!result.ok || !result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "❌ Failed to supersede." }] };
  }

  const factVal = result.data.rows[0]?.fn_supersede_fact;
  if (factVal === -1) {
    return { content: [{ type: "text" as const, text: `⚠️ Slug "${slug}" not found — nothing to supersede.` }] };
  }

  return { content: [{ type: "text" as const, text: `🔄 Superseded (new_id=${factVal}) ✓` }] };
};

server.tool(
  "ltm_supersede_fact",
  { slug: z.string(), new_title: z.string() },
  handleSupersedeFact
);
registerHandler("ltm_supersede_fact", handleSupersedeFact);

const handleVerifyFact = async ({ slug, result_val }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const verify_result = await withClient(async (client) => {
    return client.query(
      `SELECT fn_verify_fact($1, $2)`,
      [slug, result_val]
    );
  });

  if (!verify_result.ok || !verify_result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "❌ Verification failed." }] };
  }

  const code = verify_result.data.rows[0]?.fn_verify_fact;
  if (code === -1) {
    return { content: [{ type: "text" as const, text: `⚠️ Slug "${slug}" not found — nothing to verify.` }] };
  }

  return { content: [{ type: "text" as const, text: `✓ Verified ${slug} (${result_val})` }] };
};

server.tool(
  "ltm_verify_fact",
  { slug: z.string(), result_val: z.string() },
  handleVerifyFact
);
registerHandler("ltm_verify_fact", handleVerifyFact);

const handleAddTags = async ({ slug, tags }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const tag_names = Array.isArray(tags) ? (tags as string[]) : [];

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT fn_add_tags($1, $2::text[])`,
      [slug, tag_names]
    );
  });

  if (!result.ok) {
    return { content: [{ type: "text" as const, text: "❌ Failed to add tags." }] };
  }

  // fn_add_tags returns VOID — success is indicated by no error.
  return { content: [{ type: "text" as const, text: `🏷️ Tags added for "${slug}" ✓` }] };
};

server.tool(
  "ltm_add_tags",
  { slug: z.string(), tags: z.array(z.string()).optional() },
  handleAddTags
);
registerHandler("ltm_add_tags", handleAddTags);

const handleAddContext = async ({ slug, context_name }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT fn_add_context($1, $2)`,
      [slug, context_name]
    );
  });

  if (!result.ok) {
    return { content: [{ type: "text" as const, text: "❌ Failed to add context." }] };
  }

  // fn_add_context returns VOID — success is indicated by no error.
  return { content: [{ type: "text" as const, text: `📁 Context "${context_name}" added for "${slug}" ✓` }] };
};

server.tool(
  "ltm_add_context",
  { slug: z.string(), context_name: z.string() },
  handleAddContext
);
registerHandler("ltm_add_context", handleAddContext);

const handleGetSuccessionChain = async ({ slug_prefix }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT fact_id, slug, title, body, is_current FROM fn_get_succession_chain($1)`,
      [slug_prefix]
    );
  });

  if (!result.ok || !result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "🧠 No succession history." }] };
  }

  const rows = result.data.rows;
  let output = `Succession chain for "${slug_prefix}":\n`;
  for (const r of rows) {
    const status = r.is_current ? "(current)" : "[superseded]";
    output += `\n  • [${status}] ${r.title}\n    Slug: ${r.slug}`;
    if ((typeof r.body === "string" && r.body.length > 120)) {
      output += `\n    Body: ${r.body.slice(0, 120)}…`;
    } else {
      output += `\n    Body: ${r.body || ""}`;
    }
  }

  return { content: [{ type: "text" as const, text: output }] };
};

server.tool(
  "ltm_get_succession_chain",
  { slug_prefix: z.string() }, // optional fields.
  handleGetSuccessionChain
);
registerHandler("ltm_get_succession_chain", handleGetSuccessionChain);

const handleSessionPreload = async ({ limit }: any) => {
  if (!CONNECTION_STRING) return { content: [{ type: "text" as const, text: "🧠 LTM not configured." }] };

  const p_limit = Math.min(limit ?? 10, 20); // cap at 20 to avoid context bloat.

  const result = await withClient(async (client) => {
    return client.query(
      `SELECT slug, title, body, category, preload_score FROM fn_session_preload($1)`,
      [p_limit]
    );
  });

  if (!result.ok || !result.data?.rows.length) {
    return { content: [{ type: "text" as const, text: "🧠 No memories to preload." }] };
  }

  const rows = result.data.rows;
  let output = `🧠 Session Preload (${rows.length} memory):\n`;
  for (const r of rows) {
    output += `\n  • ${r.title}`;
    if ((typeof r.body === "string" && r.body.length > 150)) {
      output += `\n    ${r.body.slice(0, 150)}…`;
    } else {
      output += `\n    ${r.body || ""}`;
    }
    output += ` [${r.category}] (score: ${r.preload_score})`;
  }

  return { content: [{ type: "text" as const, text: output }] };
};

server.tool(
  "ltm_session_preload",
  { limit: z.number().optional() },
  handleSessionPreload
);
registerHandler("ltm_session_preload", handleSessionPreload);

// ─── HTTP Transport for external tool invocation ──────────────

interface HttpRequest {
  tool: string;
  params?: Record<string, any>;
}

async function handleToolInvocation(toolName: string, params: Record<string, any>): Promise<any> {
  const handler = TOOL_HANDLERS[toolName];
  if (!handler) {
    throw new Error(`Tool "${toolName}" not found.`);
  }
  return handler(params);
}

function startHttpServer(): void {
  if (!HTTP_PORT || HTTP_PORT < 0 || HTTP_PORT > 65535) {
    console.log("[ltm-mcp] HTTP transport disabled (invalid port).");
    return;
  }

  const app = http.createServer(async (req, res) => {
    // CORS headers for local dev.
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
    res.setHeader("Access-Control-Allow-Headers", "Content-Type");

    if (req.method === "OPTIONS") {
      res.writeHead(204);
      res.end();
      return;
    }

    // Health check.
    if (req.method === "GET" && req.url === "/health") {
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ status: "ok", port: HTTP_PORT }));
      return;
    }

    // Tool invocation endpoint.
    if (req.method === "POST" && req.url?.startsWith("/api/tool")) {
      try {
        const body = await new Promise<HttpRequest>((resolve, reject) => {
          let data = "";
          req.on("data", (chunk: Buffer) => (data += chunk.toString()));
          req.on("end", () => {
            try {
              resolve(JSON.parse(data));
            } catch (err) {
              reject(err);
            }
          });
        });

        const result = await handleToolInvocation(body.tool, body.params || {});
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(result));
      } catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        res.writeHead(400, { "Content-Type": "application/json" });
        res.end(JSON.stringify({ error: msg }));
      }
      return;
    }

    // 404 for everything else.
    res.writeHead(404);
    res.end("Not found");
  });

  app.listen(HTTP_PORT, "127.0.0.1", () => {
    console.log(`[ltm-mcp] HTTP transport listening on 127.0.0.1:${HTTP_PORT}`);

    // Write port to discovery file for hook scripts.
    try {
      fs.writeFileSync(HTTP_DISCOVERY_FILE, String(HTTP_PORT), "utf8");
    } catch (err) {
      console.error("[ltm-mcp] Could not write HTTP discovery file:", err);
    }
  });

  app.on("error", (err: any) => {
    if (err.code === "EADDRINUSE") {
      console.error(`[ltm-mcp] Port ${HTTP_PORT} already in use — HTTP transport disabled.`);
    } else {
      console.error("[ltm-mcp] HTTP server error:", err.message);
    }
  });
}

// ─── Start servers ──────────────

async function main() {
  // Resolve connection string from configured provider.
  const initialized = await initConnection();

  if (!initialized) {
    console.error("[ltm-mcp] Could not resolve connection string — LTM tools will be unavailable.");
  }

  // Bootstrap connectivity test + schema migration.
  const bs = await bootstrap();
  if (!bs.connected && !CONNECTION_STRING) {
    console.error(bs.message || "🧠 LTM: not configured.");
  } else if (bs.connected) {
    console.log("[ltm-mcp] Ready on stdio transport.");
  }

  // Start HTTP transport alongside stdio.
  startHttpServer();

  // Connect to stdio transport (blocks forever).
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error(`[ltm-mcp] Fatal: ${err.message}`);
});
