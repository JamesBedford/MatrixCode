import { beforeEach, describe, it, expect } from "vitest";
import {
  MessagesStore,
  sanitizeMessages,
  cloneMessages,
  DEFAULT_MESSAGES,
} from "../src/config/messagesStore.ts";

class MemoryStorage {
  private m = new Map<string, string>();
  getItem(k: string): string | null {
    return this.m.has(k) ? this.m.get(k)! : null;
  }
  setItem(k: string, v: string): void {
    this.m.set(k, v);
  }
  removeItem(k: string): void {
    this.m.delete(k);
  }
}

beforeEach(() => {
  (globalThis as unknown as { localStorage: MemoryStorage }).localStorage = new MemoryStorage();
});

describe("sanitizeMessages", () => {
  it("caps the number of messages and the text length", () => {
    const many = Array.from({ length: 30 }, () => "a".repeat(300));
    const s = sanitizeMessages({ messages: many });
    expect(s.messages.length).toBe(12);
    expect(s.messages[0]!.length).toBe(120);
  });

  it("drops blank/non-string messages", () => {
    const s = sanitizeMessages({ messages: ["ok", "", 5, null, "two"] });
    expect(s.messages).toEqual(["ok", "two"]);
  });

  it("allows an empty message list (user cleared it)", () => {
    expect(sanitizeMessages({ messages: [] }).messages).toEqual([]);
    expect(sanitizeMessages({ messages: ["  "] }).messages).toEqual([]);
  });

  it("clamps frequency and persistence and coerces enabled", () => {
    const hi = sanitizeMessages({ frequencyMs: 9_999_999, persistenceMs: 9_999_999, enabled: "yes" });
    expect(hi.frequencyMs).toBe(600000);
    expect(hi.persistenceMs).toBe(600000);
    expect(hi.enabled).toBe(DEFAULT_MESSAGES.enabled); // non-boolean → default
    const lo = sanitizeMessages({ frequencyMs: -5, persistenceMs: -5, enabled: false });
    expect(lo.frequencyMs).toBe(500);
    expect(lo.persistenceMs).toBe(500);
    expect(lo.enabled).toBe(false);
  });

  it("uses defaults for missing fields and garbage input", () => {
    const s = sanitizeMessages("garbage");
    expect(s.frequencyMs).toBe(DEFAULT_MESSAGES.frequencyMs);
    expect(s.persistenceMs).toBe(DEFAULT_MESSAGES.persistenceMs);
    expect(s.enabled).toBe(DEFAULT_MESSAGES.enabled);
  });
});

describe("cloneMessages", () => {
  it("deep-copies the messages array so mutations don't leak", () => {
    const a = cloneMessages(DEFAULT_MESSAGES);
    a.messages.push("changed");
    expect(DEFAULT_MESSAGES.messages).not.toContain("changed");
  });
});

describe("MessagesStore", () => {
  it("returns defaults with no stored value", () => {
    expect(new MessagesStore().get().messages).toEqual(DEFAULT_MESSAGES.messages);
  });

  it("persists across instances (round-trip)", () => {
    const a = new MessagesStore();
    a.set({ messages: ["NEO"], enabled: false, frequencyMs: 3000, persistenceMs: 1500 });
    const b = new MessagesStore();
    expect(b.get()).toEqual({ messages: ["NEO"], enabled: false, frequencyMs: 3000, persistenceMs: 1500 });
  });

  it("reset clears storage and returns defaults", () => {
    const s = new MessagesStore();
    s.set({ messages: ["X"], enabled: false, frequencyMs: 1000, persistenceMs: 1000 });
    const after = s.reset();
    expect(after.messages).toEqual(DEFAULT_MESSAGES.messages);
    expect(new MessagesStore().get().messages).toEqual(DEFAULT_MESSAGES.messages);
  });

  it("falls back to defaults on malformed stored JSON", () => {
    localStorage.setItem("mx-messages", "{not json");
    expect(new MessagesStore().get().frequencyMs).toBe(DEFAULT_MESSAGES.frequencyMs);
  });
});
