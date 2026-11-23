// ─── LTM MCP server — stdio transport entrypoint ────────────────
// This process owns ONLY the stdio transport (Claude Code connects one per session).
// It registers every tool synchronously at import so they're available immediately,
// then connects the stdio transport BEFORE any DB work — bootstrap() runs in the
// background so slow connection resolution / schema migration can never make Claude
// Code defer the tools. The HTTP transport is a separate singleton daemon
// (http-daemon.ts); this file does NOT start it.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { initConnection, bootstrap } from "./db.js";
import { registerOnServer, buildToolDefinitions } from "./tools.js";

// Detect old-style plaintext config (user pasted connection string into provider field).
const PROVIDER = process.env.LTM_PROVIDER || "keychain";
if (PROVIDER.startsWith("postgresql://") || PROVIDER.startsWith("postgres://")) {
  console.error(
    "[ltm-mcp] DEPRECATED: It looks like you put a PostgreSQL connection string in the LTM_PROVIDER setting." +
      "\n   The plugin no longer stores credentials as plaintext. Please:" +
      "\n   1. Store your connection string in your chosen provider under 'LTM-DB' (see README for commands)" +
      "\n   2. Set LTM_PROVIDER to: aws, 1password, or keychain" +
      "\n   Or export LTM_DB_URL as an environment variable for local development."
  );
}

// Register all tools synchronously — they're ready the moment this module loads.
const server = new McpServer({ name: "ltm-postgres", version: "1.1.8" });
registerOnServer(server, buildToolDefinitions());

async function main(): Promise<void> {
  // Resolve connection string from configured provider (variable latency).
  const initialized = await initConnection();
  if (!initialized) {
    console.error("[ltm-mcp] Could not resolve connection string — LTM tools will be unavailable.");
  }

  // Bootstrap connectivity + schema migration in the BACKGROUND. This is the key
  // fix: we no longer gate the stdio handshake behind DB work. Tools are already
  // registered; a slow bootstrap only affects whether tool *calls* succeed, never
  // whether Claude Code can enumerate them.
  void bootstrap().then((bs) => {
    if (bs.connected) {
      console.log("[ltm-mcp] Stdio transport ready on stdio.");
    } else {
      console.error(bs.message || "🧠 LTM: not configured.");
    }
  });

  // Connect to stdio transport (blocks forever). Handshake completes as soon as
  // this line runs — before bootstrap() finishes.
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error(`[ltm-mcp] Fatal: ${err.message}`);
});
