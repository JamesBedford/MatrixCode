import { describe, it, expect } from "vitest";
import { sanitizeCountdown, cloneCountdown, DEFAULT_COUNTDOWN } from "../src/config/countdownStore.ts";

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
    const a = { targetMs: 123 };
    const b = cloneCountdown(a);
    expect(b).toEqual(a);
    expect(b).not.toBe(a);
  });
});
