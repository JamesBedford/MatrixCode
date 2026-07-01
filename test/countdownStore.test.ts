import { describe, it, expect } from "vitest";
import { sanitizeCountdown, cloneCountdown, DEFAULT_COUNTDOWN, CountdownStore } from "../src/config/countdownStore.ts";

describe("sanitizeCountdown", () => {
  it("defaults to a null target", () => {
    expect(sanitizeCountdown({}).targetMs).toBeNull();
    expect(sanitizeCountdown(null).targetMs).toBeNull();
    expect(sanitizeCountdown(undefined).targetMs).toBeNull();
    expect(DEFAULT_COUNTDOWN.targetMs).toBeNull();
  });

  it("keeps a finite number", () => {
    const t = new Date(2026, 6, 1, 12, 0, 0).getTime();
    expect(sanitizeCountdown({ targetMs: t }).targetMs).toBe(t);
  });

  it("clamps out-of-range numbers into the valid Date span", () => {
    expect(sanitizeCountdown({ targetMs: -1000 }).targetMs).toBe(0);
    expect(sanitizeCountdown({ targetMs: 1e300 }).targetMs).toBe(8.64e15);
  });

  it("rejects non-numbers, NaN and Infinity → null", () => {
    expect(sanitizeCountdown({ targetMs: "soon" }).targetMs).toBeNull();
    expect(sanitizeCountdown({ targetMs: NaN }).targetMs).toBeNull();
    expect(sanitizeCountdown({ targetMs: Infinity }).targetMs).toBeNull();
    expect(sanitizeCountdown({ targetMs: null }).targetMs).toBeNull();
  });

  it("round-trips a valid doc", () => {
    const t = 1_800_000_000_000;
    const doc = sanitizeCountdown({ targetMs: t });
    expect(sanitizeCountdown(JSON.parse(JSON.stringify(doc)))).toEqual(doc);
  });
});

describe("cloneCountdown", () => {
  it("makes an independent copy", () => {
    const a = { targetMs: 123, moments: [] };
    const b = cloneCountdown(a);
    expect(b).toEqual(a);
    expect(b).not.toBe(a);
  });

  it("deep-copies the moments array", () => {
    const src = { targetMs: null, moments: [{ name: "a", targetMs: 1 }] };
    const copy = cloneCountdown(src);
    copy.moments[0]!.name = "b";
    expect(src.moments[0]!.name).toBe("a");
  });
});

describe("sanitizeCountdown — named moments", () => {
  it("migrates an old { targetMs } blob to an empty moments list", () => {
    expect(sanitizeCountdown({ targetMs: 123 })).toEqual({ targetMs: 123, moments: [] });
  });

  it("keeps valid moments and clamps negative targets to 0", () => {
    const doc = sanitizeCountdown({
      targetMs: null,
      moments: [{ name: "launch", targetMs: 1000 }, { name: "past", targetMs: -5 }],
    });
    expect(doc.moments).toEqual([
      { name: "launch", targetMs: 1000 },
      { name: "past", targetMs: 0 },
    ]);
  });

  it("strips : { } from names and trims whitespace", () => {
    const doc = sanitizeCountdown({ moments: [{ name: "  la:un{ch}  ", targetMs: 5 }] });
    expect(doc.moments).toEqual([{ name: "launch", targetMs: 5 }]);
  });

  it("drops empty-named moments and de-dupes keeping the first", () => {
    const doc = sanitizeCountdown({
      moments: [
        { name: "", targetMs: 1 },
        { name: "a", targetMs: 2 },
        { name: "a", targetMs: 3 },
      ],
    });
    expect(doc.moments).toEqual([{ name: "a", targetMs: 2 }]);
  });

  it("nulls a non-numeric moment target", () => {
    const doc = sanitizeCountdown({ moments: [{ name: "x", targetMs: "soon" }] });
    expect(doc.moments).toEqual([{ name: "x", targetMs: null }]);
  });
});

describe("CountdownStore.reset — moments", () => {
  it("clears both the default target and moments", () => {
    const s = new CountdownStore();
    s.set({ targetMs: 5, moments: [{ name: "a", targetMs: 1 }] });
    expect(s.reset()).toEqual({ targetMs: null, moments: [] });
    expect(DEFAULT_COUNTDOWN.moments).toEqual([]);
  });
});
