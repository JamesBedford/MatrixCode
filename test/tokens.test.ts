import { describe, it, expect } from "vitest";
import { resolveTokens, strftime, formatCountdown, DEFAULT_USER_NAME, momentHint } from "../src/sim/tokens.ts";

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

// Build an epoch-ms from local components so assertions are timezone-independent.
// NOTE: months are 1-indexed here (human-friendly), unlike the `at` helper above (0-indexed JS months).
const AT = (y: number, mo: number, d: number, h: number, mi: number, s = 0): number =>
  new Date(y, mo - 1, d, h, mi, s).getTime();

describe("resolveTokens — countup & named moments", () => {
  const now = AT(2026, 7, 1, 12, 0, 0);

  it("{countup} mirrors {countdown} for the same delta", () => {
    const target = now - 3_661_000; // 1h 1m 1s ago
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: target })).toBe("01:01:01");
  });

  it("{countdown:NAME} and {countup:NAME} resolve via the moments record", () => {
    const ctx = {
      name: "",
      nowMs: now,
      countdownTargetMs: null,
      moments: { launch: now + 60_000, born: now - 120_000 },
    };
    expect(resolveTokens("{countdown:launch}", ctx)).toBe("01:00");
    expect(resolveTokens("{countup:born}", ctx)).toBe("02:00");
  });

  it("an unknown name resolves to 00:00", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: {} };
    expect(resolveTokens("{countdown:nope}", ctx)).toBe("00:00");
  });

  it("countup on a future moment clamps to 00:00", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: { soon: now + 60_000 } };
    expect(resolveTokens("{countup:soon}", ctx)).toBe("00:00");
  });

  it("trims the captured name", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: { launch: now + 60_000 } };
    expect(resolveTokens("{countdown: launch }", ctx)).toBe("01:00");
  });

  it("bare tokens use the default target; null default → 00:00", () => {
    expect(resolveTokens("{countdown}", { name: "", nowMs: now, countdownTargetMs: null })).toBe("00:00");
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: now - 60_000 })).toBe("01:00");
  });
});

describe("resolveTokens — built-in holidays & run-time countup", () => {
  it("{countdown:christmas} counts down to Dec 25 07:00", () => {
    const now = AT(2026, 12, 20, 7, 0, 0); // exactly 5 days before
    expect(resolveTokens("{countdown:christmas}", { name: "", nowMs: now, countdownTargetMs: null })).toBe("05:00:00:00");
  });

  it("{countdown:christmas} holds at 00:00 during Christmas day", () => {
    const now = AT(2026, 12, 25, 15, 0, 0);
    expect(resolveTokens("{countdown:christmas}", { name: "", nowMs: now, countdownTargetMs: null })).toBe("00:00");
  });

  it("a user moment overrides a built-in holiday of the same name", () => {
    const now = AT(2026, 7, 1, 12, 0, 0);
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: { christmas: now + 60_000 } };
    expect(resolveTokens("{countdown:christmas}", ctx)).toBe("01:00");
  });

  it("bare {countup} counts up from runStartMs when no default target is set", () => {
    const now = AT(2026, 7, 1, 12, 0, 0);
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: null, runStartMs: now - 65_000 })).toBe("01:05");
  });

  it("bare {countup} still shows 00:00 with neither a target nor a run start", () => {
    const now = AT(2026, 7, 1, 12, 0, 0);
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: null })).toBe("00:00");
  });
});

describe("momentHint", () => {
  it("lists the user's moments as tokens plus the built-in holidays", () => {
    const h = momentHint(["launch", "party"]);
    expect(h).toContain("Your moments: {countdown:launch}, {countdown:party}");
    expect(h).toContain("Holidays");
    expect(h).toContain("christmas");
    expect(h).toContain("easter");
    expect(h).toContain("diwali");
    expect(h).toContain("{countup:…}");
  });

  it("still shows the holidays when there are no user moments", () => {
    const h = momentHint([]);
    expect(h).toContain("No named moments yet.");
    expect(h).toContain("Holidays (use {countdown:NAME}):");
    expect(h).toContain("newyear");
  });
});
