// ─── Daily Auto-Store Counter ──────────────────────────────────────
// Tracks how many memories the Stop hook has auto-stored today, so a runaway
// session can't exhaust the daily budget. The counter is owned by this module —
// not the Stop-hook bash script — which means it measures *actual stores* rather
// than Stop-hook fires: a long multi-hour session can't burn its whole daily
// allowance on turns that never stored anything.
//
// File format matches bootstrap.sh's daily-rollover reset: "count|YYYY-MM-DD".
// Everything here is pure and side-effect-free except incrementDailyStoreCount,
// which does the single best-effort file read/write (and never throws).

import * as fs from "fs";
import * as path from "path";

export const DAILY_STORE_LIMIT = 500;

/** Parse a counter file's contents into { count, date }. Empty/corrupt -> zeros. */
export function parseStoreCount(content: string): { count: number; date: string } {
  const trimmed = content.trim();
  if (!trimmed) return { count: 0, date: "" };
  const [countStr, dateStr] = trimmed.split("|");
  const count = parseInt(countStr, 10);
  return { count: Number.isNaN(count) ? 0 : count, date: (dateStr ?? "").trim() };
}

/**
 * Compute next store count given today's file content and the current calendar day.
 * Rolls over to a fresh count when the stored date is not today. Pure — no I/O.
 */
export function computeNextStoreCount(content: string, today: string): { count: number; date: string } {
  const { count, date } = parseStoreCount(content);
  // Roll over to a fresh count if the calendar day changed since last store.
  const next = (date !== today ? 0 : count) + 1;
  return { count: next, date: today };
}

/** Read today's stored count from disk. Tolerates missing/empty/corrupt files -> 0. */
export function readStoreCount(file: string): number {
  try {
    const content = fs.readFileSync(file, "utf8").trim();
    return parseStoreCount(content).count;
  } catch {
    // Missing file (first run) or unreadable directory — treat as zero.
    return 0;
  }
}

/**
 * Increment the daily store counter and persist it. Best-effort: never throws, so a
 * failed write can't break the store itself. Returns the new count.
 * @param file counter file path (defaults to CLAUDE_PLUGIN_DATA/ltm_session_store_count)
 * @param today ISO date string (defaults to now); injectable for deterministic tests
 */
export function incrementDailyStoreCount(
  file: string = path.join(process.env.CLAUDE_PLUGIN_DATA || "/tmp", "ltm_session_store_count"),
  today: string = new Date().toISOString().slice(0, 10)
): number {
  // Read the existing count. A missing file (first run) or unreadable directory is
  // not an error here — it just means we start at zero.
  let current = 0;
  try {
    const content = fs.readFileSync(file, "utf8");
    const parsed = parseStoreCount(content);
    current = parsed.date !== today ? 0 : parsed.count;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== "ENOENT") {
      console.error(`[ltm-mcp] Could not read daily store count (${(err as Error).message}).`);
    }
  }

  const next = current + 1;

  // Persist the new count. A write failure must never break the store itself, so we
  // swallow it — but log it so a misconfigured data dir is visible in the debug logs.
  try {
    fs.writeFileSync(file, `${next}|${today}`, "utf8");
    if (next >= DAILY_STORE_LIMIT) {
      console.log(`[ltm-mcp] Daily auto-store cap reached (${DAILY_STORE_LIMIT}/day).`);
    }
  } catch (err) {
    console.error(`[ltm-mcp] Could not persist daily store count (${(err as Error).message}).`);
  }

  return next;
}
