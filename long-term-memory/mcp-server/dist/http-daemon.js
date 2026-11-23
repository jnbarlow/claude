// ─── Singleton HTTP daemon (shared transport) ─────────────────────
// A single long-lived process that owns the loopback HTTP endpoint every hook
// script talks to. Unlike the old in-process server, this daemon:
//   - binds an EPHEMERAL free port and persists it to ltm-mcp-port.txt (hooks
//     already read that file), so two plugin installs / sessions never collide
//     on a fixed port;
//   - EXITS cleanly if the port is taken — another daemon owns it, so there's no
//     infinite EADDRINUSE backoff spinning in losing processes.
// It runs bootstrap() (connectivity + schema migration) once at startup but does
// NOT gate any stdio handshake behind it — this process has no stdio transport,
// so slow DB work here can't make Claude Code defer tools.
import * as http from "http";
import * as fs from "fs";
import * as path from "path";
import * as crypto from "crypto";
import { initConnection, bootstrap } from "./db.js";
import { buildToolDefinitions } from "./tools.js";
const HTTP_AUTH_TOKEN_FILE = path.join(process.env.CLAUDE_PLUGIN_DATA || "/tmp", "ltm-mcp-auth.txt");
// Shared-secret auth for the loopback /api/tool endpoint. The daemon generates a
// random token at startup (or uses LTM_HTTP_AUTH_TOKEN if set) and persists it to
// ltm-mcp-auth.txt so hook scripts can read it back on every request. Without
// this, any local process can invoke destructive tools (delete/supersede/verify).
// /health stays open for liveness checks; only POST /api/tool requires the token.
const HTTP_AUTH_TOKEN = process.env.LTM_HTTP_AUTH_TOKEN?.trim() || "";
function readPersistedAuthToken() {
    try {
        const existing = fs.readFileSync(HTTP_AUTH_TOKEN_FILE, "utf8").trim();
        return existing || null;
    }
    catch {
        return null;
    }
}
function generateAndPersistAuthToken() {
    const generated = crypto.randomBytes(32).toString("hex");
    try {
        fs.writeFileSync(HTTP_AUTH_TOKEN_FILE, generated, "utf8");
        try {
            fs.chmodSync(HTTP_AUTH_TOKEN_FILE, 0o600);
        }
        catch {
            /* chmod is best-effort on platforms that don't support it */
        }
        return generated;
    }
    catch (err) {
        const msg = err instanceof Error ? err.message : String(err);
        console.error(`[ltm-mcp] Could not write shared auth token to ${HTTP_AUTH_TOKEN_FILE} (${msg}); ` +
            "using an ephemeral in-memory secret instead.");
        return null;
    }
}
function resolveHttpAuthToken() {
    if (HTTP_AUTH_TOKEN)
        return HTTP_AUTH_TOKEN;
    const existing = readPersistedAuthToken();
    if (existing)
        return existing;
    return generateAndPersistAuthToken() ?? crypto.randomBytes(32).toString("hex");
}
const HTTP_AUTH_SECRET = resolveHttpAuthToken();
function isAuthed(req) {
    const header = req.headers["x-ltm-token"];
    const provided = typeof header === "string" ? header : Array.isArray(header) ? header[0] ?? "" : "";
    if (!provided)
        return false;
    const a = Buffer.from(provided, "utf8");
    const b = Buffer.from(HTTP_AUTH_SECRET, "utf8");
    if (a.length !== b.length)
        return false;
    // Timing-safe comparison to avoid leaking token length/content via timing.
    return crypto.timingSafeEqual(a, b);
}
const TOOL_HANDLERS = new Map();
for (const def of buildToolDefinitions()) {
    TOOL_HANDLERS.set(def.name, def.handler);
}
async function handleToolInvocation(toolName, params) {
    const handler = TOOL_HANDLERS.get(toolName);
    if (!handler)
        throw new Error(`Tool "${toolName}" not found.`);
    return handler(params);
}
// Bind the HTTP server on an ephemeral free port (port 0 → OS assigns one), then
// persist the assigned port. Binding once avoids the classic "discover a free
// port, release it, re-bind" race — we hold the socket for the daemon's lifetime.
function startDaemon() {
    let PORT = 0;
    const app = http.createServer(async (req, res) => {
        res.setHeader("Access-Control-Allow-Origin", "*");
        res.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
        res.setHeader("Access-Control-Allow-Headers", "Content-Type");
        if (req.method === "OPTIONS") {
            res.writeHead(204);
            res.end();
            return;
        }
        // Health check — open so hooks / other processes can probe liveness.
        if (req.method === "GET" && req.url === "/health") {
            res.writeHead(200, { "Content-Type": "application/json" });
            res.end(JSON.stringify({ status: "ok", port: PORT }));
            return;
        }
        // Tool invocation endpoint — requires the shared-secret token header.
        if (req.method === "POST" && req.url?.startsWith("/api/tool")) {
            if (!isAuthed(req)) {
                res.writeHead(401, { "Content-Type": "application/json" });
                res.end(JSON.stringify({ error: "missing or invalid auth token" }));
                return;
            }
            try {
                const body = await new Promise((resolve, reject) => {
                    let data = "";
                    req.on("data", (chunk) => (data += chunk.toString()));
                    req.on("end", () => {
                        try {
                            resolve(JSON.parse(data));
                        }
                        catch (err) {
                            reject(err);
                        }
                    });
                });
                const result = await handleToolInvocation(body.tool, body.params || {});
                res.writeHead(200, { "Content-Type": "application/json" });
                res.end(JSON.stringify(result));
            }
            catch (err) {
                const msg = err instanceof Error ? err.message : String(err);
                res.writeHead(400, { "Content-Type": "application/json" });
                res.end(JSON.stringify({ error: msg }));
            }
            return;
        }
        res.writeHead(404);
        res.end("Not found");
    });
    app.on("error", (err) => {
        if (err.code === "EADDRINUSE") {
            // Another daemon owns this port — exit cleanly. The singleton model means
            // there's nothing for us to do; the existing daemon keeps serving hooks.
            console.error(`[ltm-mcp] Port ${PORT} in use by another LTM daemon — exiting.`);
            process.exit(0);
        }
        else {
            console.error("[ltm-mcp] HTTP server error:", err.message);
            process.exit(1);
        }
    });
    // Bind on an ephemeral free port (port 0 → OS assigns one). We hold this socket
    // for the daemon's lifetime — no discover-then-rebind race.
    app.listen(0, "127.0.0.1", () => {
        const addr = app.address();
        if (!addr || typeof addr !== "object") {
            console.error("[ltm-mcp] Failed to read bound address; exiting.");
            process.exit(1);
        }
        PORT = addr.port;
        // Persist the port for hook scripts to read back (they already do).
        const discoveryFile = path.join(process.env.CLAUDE_PLUGIN_DATA || "/tmp", "ltm-mcp-port.txt");
        try {
            fs.writeFileSync(discoveryFile, String(PORT), "utf8");
        }
        catch (err) {
            console.error("[ltm-mcp] Could not write HTTP discovery file:", err);
        }
        console.log(`[ltm-mcp] HTTP daemon listening on 127.0.0.1:${PORT}`);
    });
}
export async function runHttpDaemon() {
    // Resolve connection string from configured provider.
    const initialized = await initConnection();
    if (!initialized) {
        console.error("[ltm-mcp] Could not resolve connection string — HTTP daemon will still serve /health.");
    }
    // Bootstrap connectivity + schema migration (once). This process has no stdio
    // transport, so slow DB work here does NOT gate any Claude Code handshake.
    const bs = await bootstrap();
    if (!bs.connected) {
        console.error(bs.message || "🧠 LTM: not configured.");
    }
    else {
        console.log("[ltm-mcp] HTTP daemon ready (DB connected).");
    }
    // Bind an ephemeral free port and serve forever. If the port is taken, we exit
    // — another daemon already owns it.
    startDaemon();
}
