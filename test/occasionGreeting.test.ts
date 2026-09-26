import { afterEach, describe, expect, it, vi } from "vitest";

import { occasionGreeting } from "../src/sim/occasionGreeting.ts";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("occasion greetings", () => {
  it("names Valentine's Day, Christmas, and St Patrick's Day for the whole local day", () => {
    expect(occasionGreeting(new Date(2026, 1, 14, 12))).toBe("happy valentine's day!");
    expect(occasionGreeting(new Date(2026, 11, 25, 0))).toBe("happy christmas");
    expect(occasionGreeting(new Date(2026, 2, 17, 23))).toBe("happy st. patrick's day");
    expect(occasionGreeting(new Date(2026, 2, 18, 12))).toBeNull();
    expect(occasionGreeting(new Date(2026, 1, 13, 12))).toBeNull();
  });

  it("uses the full-moon greeting only when no fixed holiday wins", () => {
    vi.stubEnv("TZ", "UTC");
    expect(occasionGreeting(new Date("2026-09-26T12:00:00Z"))).toBe("happy full moon");
    expect(occasionGreeting(new Date("2026-09-25T12:00:00Z"))).toBeNull();
    expect(occasionGreeting(new Date("2033-02-14T12:00:00Z"))).toBe("happy valentine's day!");
  });
});
