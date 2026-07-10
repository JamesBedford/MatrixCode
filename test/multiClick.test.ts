import { describe, expect, it } from "vitest";
import { advanceMultiClick, settledMultiClickAction } from "../src/sim/multiClick.ts";

describe("backdrop multi-click gesture", () => {
  it("waits after click two so a fullscreen transition cannot swallow click three", () => {
    const first = advanceMultiClick(0);
    const second = advanceMultiClick(first.count);
    expect(first).toEqual({ count: 1, action: "wait" });
    expect(second).toEqual({ count: 2, action: "wait" });
    expect(settledMultiClickAction(second.count)).toBe("fullscreen");
  });

  it("launches multi-monitor mode immediately on click three", () => {
    const third = advanceMultiClick(advanceMultiClick(advanceMultiClick(0).count).count);
    expect(third).toEqual({ count: 0, action: "multiMonitor" });
  });

  it("does nothing when a single-click sequence settles", () => {
    expect(settledMultiClickAction(1)).toBe("none");
  });
});
