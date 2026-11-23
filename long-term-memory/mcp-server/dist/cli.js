// ─── CLI entrypoint ──────────────────────────────────────────────
// Dispatches based on argv:
//   node dist/cli.js --daemon   → start the singleton HTTP daemon (foreground)
//   (no args)                   → print usage and exit 0
//
// The stdio transport is started by index.ts (Claude Code's MCP entrypoint), so
// this file exists purely to launch the HTTP daemon without importing it.
import { runHttpDaemon } from "./http-daemon.js";
async function main() {
    const arg = process.argv[2];
    if (arg === "--daemon") {
        await runHttpDaemon();
        return;
    }
    console.log("Usage:");
    console.log("  node dist/cli.js --daemon   Start the singleton HTTP transport daemon.");
    console.log("");
    console.log("The stdio transport is started separately by index.ts (Claude Code's MCP entrypoint).");
    process.exit(0);
}
main().catch((err) => {
    console.error(`[ltm-mcp] Fatal: ${err.message}`);
    process.exit(1);
});
