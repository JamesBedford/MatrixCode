import { describe, it, expect } from "vitest";
import { resolveTokens, strftime, formatCountdown, DEFAULT_USER_NAME } from "../src/sim/tokens.ts";

// All clocks/targets are built via new Date(y, m, d, ...) (local time) and formatted via the same
// local getters, so these assertions are timezone-independent.
const at = (y: number, mo: number, d: number, h = 0, mi = 0, s = 0): number =>
  new Date(y, mo, d, h, mi, s).getTime();

const ctx = (over: Partial<{ name: string; nowMs: number; countdownTargetMs: number | null }> = {}) => ({
  name: "Neo",
  nowMs: at(2026, 6, 1, 13, 45, 30), // 2026-07-01 13:45:30 local
  countdownTargetMs: null,
  ...over,
});

describe("resolveTokens — {name}", () => {
  it("substitutes every occurrence", () => {
    expect(resolveTokens("Hi {name}, {name}!", ctx({ name: "Trinity" }))).toBe("Hi Trinity, Trinity!");
  });
  it("falls back to the default name when blank", () => {
    expect(resolveTokens("{name}", ctx({ name: "   " }))).toBe(DEFAULT_USER_NAME);
  });
});

describe("resolveTokens — {time}", () => {
  it("defaults to HH:MM (24h)", () => {
    expect(resolveTokens("{time}", ctx())).toBe("13:45");
  });
  it("honours a strftime format", () => {
    expect(resolveTokens("{time:%I:%M %p}", ctx())).toBe("01:45 PM");
    expect(resolveTokens("{time:%H:%M:%S}", ctx())).toBe("13:45:30");
  });
  it("formats dates", () => {
    expect(resolveTokens("{time:%Y-%m-%d}", ctx())).toBe("2026-07-01");
    // 2026-07-01 is a Wednesday.
    expect(resolveTokens("{time:%A}", ctx())).toBe("Wednesday");
    expect(resolveTokens("{time:%a %b}", ctx())).toBe("Wed Jul");
  });
});

describe("strftime", () => {
  it("handles midnight in both 12h and 24h", () => {
    const midnight = new Date(2026, 0, 1, 0, 5, 0);
    expect(strftime(midnight, "%H")).toBe("00");
    expect(strftime(midnight, "%I %p")).toBe("12 AM");
  });
  it("passes unknown directives through and unescapes %%", () => {
    expect(strftime(new Date(2026, 0, 1, 9, 0, 0), "%H%% %q")).toBe("09% %q");
  });
});

describe("formatCountdown", () => {
  it("shows DD:HH:MM:SS when a day or more remains", () => {
    expect(formatCountdown((2 * 86400 + 3 * 3600 + 4 * 60 + 5) * 1000)).toBe("02:03:04:05");
  });
  it("shows HH:MM:SS between 1 and 24 hours", () => {
    expect(formatCountdown((5 * 3600 + 6 * 60 + 7) * 1000)).toBe("05:06:07");
  });
  it("shows MM:SS under an hour", () => {
    expect(formatCountdown((9 * 60 + 8) * 1000)).toBe("09:08");
  });
  it("clamps negatives to 00:00", () => {
    expect(formatCountdown(-5000)).toBe("00:00");
    expect(formatCountdown(0)).toBe("00:00");
  });
});

describe("resolveTokens — {countdown}", () => {
  it("shows DD:HH:MM:SS when the target is over a day away", () => {
    const now = at(2026, 6, 1, 0, 0, 0);
    const target = now + (2 * 86400 + 3 * 3600 + 4 * 60 + 5) * 1000;
    expect(resolveTokens("{countdown}", ctx({ nowMs: now, countdownTargetMs: target }))).toBe("02:03:04:05");
  });
  it("shows HH:MM:SS within a day", () => {
    const now = at(2026, 6, 1, 0, 0, 0);
    const target = now + (5 * 3600 + 6 * 60 + 7) * 1000;
    expect(resolveTokens("{countdown}", ctx({ nowMs: now, countdownTargetMs: target }))).toBe("05:06:07");
  });
  it("shows MM:SS within an hour", () => {
    const now = at(2026, 6, 1, 0, 0, 0);
    const target = now + (9 * 60 + 8) * 1000;
    expect(resolveTokens("{countdown}", ctx({ nowMs: now, countdownTargetMs: target }))).toBe("09:08");
  });
  it("shows 00:00 for an elapsed target", () => {
    const now = at(2026, 6, 1, 12, 0, 0);
    expect(resolveTokens("{countdown}", ctx({ nowMs: now, countdownTargetMs: now - 60000 }))).toBe("00:00");
  });
  it("shows 00:00 when no target is set", () => {
    expect(resolveTokens("{countdown}", ctx({ countdownTargetMs: null }))).toBe("00:00");
  });
});

describe("resolveTokens — mixed & unknown", () => {
  it("resolves multiple token kinds in one string", () => {
    const now = at(2026, 6, 1, 13, 45, 0);
    const target = now + (12 * 60) * 1000; // 12 minutes
    const out = resolveTokens("{name}: launch in {countdown} at {time}", ctx({ name: "Neo", nowMs: now, countdownTargetMs: target }));
    expect(out).toBe("Neo: launch in 12:00 at 13:45");
  });
  it("leaves unknown tokens untouched", () => {
    expect(resolveTokens("keep {foo} and {bar}", ctx())).toBe("keep {foo} and {bar}");
  });
});
