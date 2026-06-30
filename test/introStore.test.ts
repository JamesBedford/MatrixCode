import { beforeEach, describe, it, expect } from "vitest";
import {
  IntroStore,
  sanitizeIntro,
  cloneIntro,
  toTypeConfig,
  DEFAULT_INTRO,
} from "../src/config/introStore.ts";
import { DEFAULT_TYPE_CONFIG } from "../src/sim/messageOverlay.ts";

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

describe("sanitizeIntro", () => {
  it("clamps out-of-range numbers", () => {
    const s = sanitizeIntro({ lines: [{ text: "x", holdMs: 999999, pauseMs: -50 }], charMs: 9999, startDelayMs: -10, fadeOutMs: 999999 });
    expect(s.lines[0]!.holdMs).toBe(20000);
    expect(s.lines[0]!.pauseMs).toBe(0);
    expect(s.charMs).toBe(500);
    expect(s.startDelayMs).toBe(0);
    expect(s.fadeOutMs).toBe(10000);
  });

  it("caps the number of lines and the text length", () => {
    const many = Array.from({ length: 30 }, () => ({ text: "a".repeat(300), holdMs: 100, pauseMs: 0 }));
    const s = sanitizeIntro({ lines: many });
    expect(s.lines.length).toBe(12);
    expect(s.lines[0]!.text.length).toBe(120);
  });

  it("drops malformed lines and uses fallbacks for missing fields", () => {
    const s = sanitizeIntro({ lines: [null, 5, { text: "ok" }, "nope"] });
    expect(s.lines.length).toBe(1);
    expect(s.lines[0]!.text).toBe("ok");
    expect(s.lines[0]!.holdMs).toBe(DEFAULT_INTRO.lines[0]!.holdMs);
    expect(s.lines[0]!.pauseMs).toBe(0);
  });

  it("falls back to default lines when none are valid or the array is empty", () => {
    expect(sanitizeIntro({ lines: [] }).lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(sanitizeIntro({}).lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(sanitizeIntro("garbage").charMs).toBe(DEFAULT_INTRO.charMs);
  });
});

describe("toTypeConfig", () => {
  it("builds a TypeConfig including the default blink period", () => {
    const cfg = toTypeConfig({ lines: [], charMs: 80, startDelayMs: 100, fadeOutMs: 200, rainDuringIntro: true, postIntroDelayMs: 0 });
    expect(cfg.charMs).toBe(80);
    expect(cfg.startDelayMs).toBe(100);
    expect(cfg.fadeOutMs).toBe(200);
    expect(cfg.blinkMs).toBe(DEFAULT_TYPE_CONFIG.blinkMs);
  });
});

describe("sanitizeIntro — rain fields", () => {
  it("defaults the rain fields when missing", () => {
    const s = sanitizeIntro({});
    expect(s.rainDuringIntro).toBe(true);
    expect(s.postIntroDelayMs).toBe(0);
  });

  it("clamps post-intro delay (0–10000)", () => {
    const hi = sanitizeIntro({ postIntroDelayMs: 99999 });
    expect(hi.postIntroDelayMs).toBe(10000);
    const lo = sanitizeIntro({ postIntroDelayMs: -50 });
    expect(lo.postIntroDelayMs).toBe(0);
  });

  it("coerces rainDuringIntro to a boolean, defaulting non-booleans to true", () => {
    expect(sanitizeIntro({ rainDuringIntro: false }).rainDuringIntro).toBe(false);
    expect(sanitizeIntro({ rainDuringIntro: "no" }).rainDuringIntro).toBe(true);
  });
});

describe("cloneIntro", () => {
  it("deep-copies lines so mutations don't leak", () => {
    const a = cloneIntro(DEFAULT_INTRO);
    a.lines[0]!.text = "changed";
    expect(DEFAULT_INTRO.lines[0]!.text).not.toBe("changed");
  });
});

describe("IntroStore", () => {
  it("returns defaults with no stored value", () => {
    expect(new IntroStore().get().lines.length).toBe(DEFAULT_INTRO.lines.length);
  });

  it("persists across instances (round-trip)", () => {
    const a = new IntroStore();
    a.set({ lines: [{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }], charMs: 50, startDelayMs: 0, fadeOutMs: 0, rainDuringIntro: false, postIntroDelayMs: 1500 });
    const b = new IntroStore();
    expect(b.get().lines).toEqual([{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }]);
    expect(b.get().charMs).toBe(50);
    expect(b.get().rainDuringIntro).toBe(false);
    expect(b.get().postIntroDelayMs).toBe(1500);
  });

  it("reset clears storage and returns defaults", () => {
    const s = new IntroStore();
    s.set({ lines: [{ text: "x", holdMs: 1, pauseMs: 1 }], charMs: 50, startDelayMs: 1, fadeOutMs: 1, rainDuringIntro: false, postIntroDelayMs: 1 });
    const after = s.reset();
    expect(after.lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(new IntroStore().get().lines.length).toBe(DEFAULT_INTRO.lines.length);
  });

  it("falls back to defaults on malformed stored JSON", () => {
    localStorage.setItem("mx-intro", "{not json");
    expect(new IntroStore().get().charMs).toBe(DEFAULT_INTRO.charMs);
  });
});
