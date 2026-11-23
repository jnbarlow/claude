import { buildToolDefinitions } from "../src/tools.js";
import z from "zod";

// These tests lock in the single-source-of-truth contract: both the stdio server
// (index.ts) and the HTTP daemon (http-daemon.ts) register tools from this exact
// list. If a tool is added, removed, or renamed here, BOTH transports change —
// so asserting names + required-schema presence is the cheapest guard against drift.

const defs = buildToolDefinitions();
const byName = new Map(defs.map((d) => [d.name, d]));

describe("buildToolDefinitions", () => {
  it("defines exactly the expected set of tools", () => {
    const names = [...byName.keys()].sort();
    expect(names).toEqual(
      [
        "ltm_add_context",
        "ltm_add_tags",
        "ltm_delete_fact",
        "ltm_get_succession_chain",
        "ltm_list_memories",
        "ltm_recall_by_text",
        "ltm_recall_by_topic",
        "ltm_session_preload",
        "ltm_store_memory",
        "ltm_supersede_fact",
        "ltm_verify_fact",
      ].sort()
    );
  });

  it("gives every tool a unique name (no collisions)", () => {
    const all = defs.map((d) => d.name);
    expect(all.length).toBe(new Set(all).size);
  });

  it("exposes a Zod schema for every tool", () => {
    for (const def of defs) {
      expect(def.schema).toBeDefined();
      // A raw shape is an object; the McpServer validates it at registration.
      expect(typeof def.schema).toBe("object");
    }
  });

  it("marks ltm_store_memory.slug as required", () => {
    const slug = byName.get("ltm_store_memory")!.schema.slug as any;
    // Required (non-optional) string field.
    expect(slug.safeParse(undefined).success).toBe(false);
  });

  it("marks ltm_recall_by_text.query as required", () => {
    const query = byName.get("ltm_recall_by_text")!.schema.query as any;
    expect(query.safeParse(undefined).success).toBe(false);
  });

  it("makes ltm_store_memory.tags optional", () => {
    const tags = byName.get("ltm_store_memory")!.schema.tags as any;
    // Optional field parses undefined successfully.
    expect(tags.safeParse(undefined).success).toBe(true);
  });

  it("every handler is a function", () => {
    for (const def of defs) {
      expect(typeof def.handler).toBe("function");
    }
  });
});
