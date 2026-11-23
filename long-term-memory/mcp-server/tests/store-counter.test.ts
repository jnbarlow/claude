import {
  DAILY_STORE_LIMIT,
  incrementDailyStoreCount,
  parseStoreCount,
  computeNextStoreCount,
  readStoreCount,
} from "../src/store-counter.js";

import * as fs from "fs";
import * as os from "os";
import * as path from "path";

describe("parseStoreCount", () => {
  it("parses a valid count|date string", () => {
    expect(parseStoreCount("42|2026-11-23")).toEqual({ count: 42, date: "2026-11-23" });
  });

  it("returns zeros for empty input", () => {
    expect(parseStoreCount("")).toEqual({ count: 0, date: "" });
    expect(parseStoreCount("   ")).toEqual({ count: 0, date: "" });
  });

  it("treats a non-numeric count as zero", () => {
    expect(parseStoreCount("abc|2026-11-23")).toEqual({ count: 0, date: "2026-11-23" });
  });

  it("handles a missing date field gracefully", () => {
    expect(parseStoreCount("7")).toEqual({ count: 7, date: "" });
  });
});

describe("computeNextStoreCount", () => {
  it("increments the same-day count", () => {
    expect(computeNextStoreCount("3|2026-11-23", "2026-11-23")).toEqual({
      count: 4,
      date: "2026-11-23",
    });
  });

  it("rolls over to a fresh count when the day changed", () => {
    expect(computeNextStoreCount("499|2026-11-22", "2026-11-23")).toEqual({
      count: 1,
      date: "2026-11-23",
    });
  });

  it("starts at 1 for empty input (first run)", () => {
    expect(computeNextStoreCount("", "2026-11-23")).toEqual({ count: 1, date: "2026-11-23" });
  });

  it("rolls over from a stale date even when the count is zero", () => {
    expect(computeNextStoreCount("0|2026-11-20", "2026-11-23")).toEqual({
      count: 1,
      date: "2026-11-23",
    });
  });
});

describe("readStoreCount", () => {
  it("reads the stored count from a file", () => {
    const file = path.join(os.tmpdir(), `ltm-count-${Date.now()}.txt`);
    try {
      fs.writeFileSync(file, "10|2026-11-23", "utf8");
      expect(readStoreCount(file)).toBe(10);
    } finally {
      fs.rmSync(file);
    }
  });

  it("returns 0 when the file is missing", () => {
    expect(readStoreCount("/nonexistent/path/ltm_session_store_count")).toBe(0);
  });

  it("returns 0 for an empty or corrupt file", () => {
    const file = path.join(os.tmpdir(), `ltm-count-corrupt-${Date.now()}.txt`);
    try {
      fs.writeFileSync(file, "", "utf8");
      expect(readStoreCount(file)).toBe(0);
    } finally {
      fs.rmSync(file);
    }
  });
});

describe("incrementDailyStoreCount", () => {
  function tmpFile(): string {
    return path.join(os.tmpdir(), `ltm-count-${Date.now()}-${Math.random().toString(36).slice(2)}.txt`);
  }

  it("creates the file and writes count=1 on first run", () => {
    const file = tmpFile();
    try {
      const next = incrementDailyStoreCount(file, "2026-11-23");
      expect(next).toBe(1);
      expect(fs.readFileSync(file, "utf8").trim()).toBe("1|2026-11-23");
    } finally {
      fs.rmSync(file);
    }
  });

  it("increments the count on subsequent calls", () => {
    const file = tmpFile();
    try {
      expect(incrementDailyStoreCount(file, "2026-11-23")).toBe(1);
      expect(incrementDailyStoreCount(file, "2026-11-23")).toBe(2);
      expect(readStoreCount(file)).toBe(2);
    } finally {
      fs.rmSync(file);
    }
  });

  it("rolls over to a fresh count when the day changes", () => {
    const file = tmpFile();
    try {
      incrementDailyStoreCount(file, "2026-11-22");
      expect(incrementDailyStoreCount(file, "2026-11-23")).toBe(1);
    } finally {
      fs.rmSync(file);
    }
  });

  it("does not throw when the write fails", () => {
    // Point at an unreadable path (e.g. a directory that doesn't exist).
    const badFile = "/nonexistent-dir/ltm_session_store_count";
    expect(() => incrementDailyStoreCount(badFile, "2026-11-23")).not.toThrow();
  });

  it("logs when the daily cap is reached", () => {
    const file = tmpFile();
    try {
      const logSpy = jest.spyOn(console, "log").mockImplementation(() => {});
      incrementDailyStoreCount(file, "2026-11-23"); // count 1
      expect(logSpy).not.toHaveBeenCalled();

      // Force the cap by writing a count at the limit.
      fs.writeFileSync(file, `${DAILY_STORE_LIMIT}|2026-11-23`, "utf8");
      incrementDailyStoreCount(file, "2026-11-23");
      expect(logSpy).toHaveBeenCalledWith(
        `[ltm-mcp] Daily auto-store cap reached (${DAILY_STORE_LIMIT}/day).`
      );
      logSpy.mockRestore();
    } finally {
      fs.rmSync(file);
    }
  });
});
