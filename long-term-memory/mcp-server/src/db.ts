// ─── Connection + pool state (shared by both transports) ──────────
// Both the stdio server (index.ts) and the HTTP daemon (http-daemon.ts) need
// the same connection string, pool, and per-query client helper. Keeping it in
// one module avoids duplicating that logic AND avoids a circular import: tools.ts
// imports this (not index.ts), so there's no index → tools → index cycle.

import { Pool, PoolClient } from "pg";
import * as fs from "fs";
import * as path from "path";
import { resolveConnectionString } from "./secret.js";

let CONNECTION_STRING: string | null = null;

/** Resolve the connection string from the configured provider / env fallback. */
export async function initConnection(): Promise<boolean> {
  CONNECTION_STRING = await resolveConnectionString(process.env.LTM_PROVIDER || "keychain");
  if (!CONNECTION_STRING) {
    console.error("[ltm-mcp] Missing connection string — could not resolve from provider.");
    return false;
  }
  return true;
}

/** Current connection string (set by initConnection). Read-only accessor. */
export function getConnectionString(): string | null {
  return CONNECTION_STRING;
}

/** Lazily create a single shared pool for the given connection string. */
export async function getPool(connectionString: string): Promise<Pool> {
  if (!CONNECTION_STRING) {
    throw new Error("Connection string not initialized — initConnection() was not called.");
  }
  // One pool per process; the connection string is fixed for a process lifetime.
  return new Pool({ connectionString });
}

/** Run a query with a pooled client, normalizing errors to { ok, data }. */
export async function withClient<T>(
  fn: (client: PoolClient) => Promise<T>
): Promise<{ ok: boolean; data?: T }> {
  if (!CONNECTION_STRING) {
    return { ok: false }; // handled by bootstrap diagnostic instead of crashing mid-tool-call.
  }
  const pool = await getPool(CONNECTION_STRING);
  const client = await pool.connect();
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

// ─── Schema discovery + bootstrap ──────────────────────────────────
// Bootstrap does the connectivity test + schema-version check + pending migration
// run. It's shared by BOTH transports (stdio server and HTTP daemon) so they stay
// in lockstep on schema version. Moved here because it needs CONNECTION_STRING,
// which now lives exclusively in this module.

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

// Discover migration files: schema_v<N>.sql in the same sql/ directory.
const MIGRATION_FILES = (() => {
  if (!SCHEMA_SQL) return [];
  const dir = path.dirname(SCHEMA_SQL);
  try {
    // Sort numerically by migration version so v10 sorts after v9 (lexicographic string sort would
    // mis-order at two digits). Only schema_v<N>.sql files are considered.
    const migrations = fs.readdirSync(dir)
      .map(name => {
        const match = name.match(/^schema_v(\d+)\.sql$/);
        if (!match) return null;
        return { version: parseInt(match[1], 10), path: path.join(dir, name) };
      })
      .filter((x): x is { version: number; path: string } => !!x)
      .sort((a, b) => a.version - b.version);
    return migrations;
  } catch {
    console.error("[ltm-mcp] Could not read sql/ directory — skipping migration discovery.");
    return [];
  }
})();

/**
 * Connectivity test + schema bootstrap. Returns whether the DB is reachable and
 * connected at its current schema version. Safe to run multiple times (idempotent).
 */
export async function bootstrap(): Promise<{ connected: boolean; message?: string }> {
  if (!CONNECTION_STRING) {
    console.error("[ltm-mcp] LTM not configured — no connection string.");
    return { connected: false, message: "🧠 LTM: Long-term memory is not configured." };
  }

  try {
    const client = await getPool(CONNECTION_STRING);
    const conn = await client.connect();

    // Test connectivity.
    await conn.query("SELECT 1");

    // Determine current schema version in database.
    let currentVer = 0;
    try {
      const check = await conn.query(
        "SELECT COALESCE(MAX(schema_version), 0) AS ver FROM ltm_initialized"
      );
      currentVer = parseInt(check.rows[0]?.ver, 10);
    } catch {
      // Marker table doesn't exist — fresh DB.
    }

    if (currentVer === 0 && SCHEMA_CONTENT) {
      // Fresh install: apply full schema.sql.
      await conn.query(SCHEMA_CONTENT);
      console.log("[ltm-mcp] Schema applied successfully.");
    } else if (currentVer > 0) {
      // Apply pending migrations in order.
      const pending = MIGRATION_FILES.filter(m => m.version > currentVer);
      for (const migration of pending) {
        try {
          const sql = fs.readFileSync(migration.path, "utf8");
          await conn.query(sql);
          console.log(`[ltm-mcp] Applied migration v${migration.version}.`);

          // Update version marker after each successful migration.
          await conn.query(
            `DELETE FROM ltm_initialized WHERE schema_version < ${migration.version}`
          );
          await conn.query(
            `INSERT INTO ltm_initialized (schema_version) VALUES (${migration.version}) ON CONFLICT DO NOTHING`
          );
        } catch (err) {
          console.error(`[ltm-mcp] Failed to apply migration v${migration.version}:`, err);
          break; // Stop on first failure — manual intervention needed.
        }
      }

      if (pending.length === 0) {
        console.log(`[ltm-mcp] Schema already at v${currentVer} — no pending migrations.`);
      } else {
        // Re-read actual applied version from DB in case some migrations failed.
        const finalCheck = await conn.query(
          "SELECT COALESCE(MAX(schema_version), 0) AS ver FROM ltm_initialized"
        );
        currentVer = parseInt(finalCheck.rows[0]?.ver, 10);
      }
    }

    conn.release();
    console.log("[ltm-mcp] Connected to PostgreSQL.");
    return { connected: true };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[ltm-mcp] Database unreachable — ${msg}`);
    return { connected: false, message: `🧠 LTM: Database unreachable at configured address.` };
  }
}
