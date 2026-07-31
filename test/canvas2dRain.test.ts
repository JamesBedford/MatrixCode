import { describe, expect, it, vi } from "vitest";

import { shouldSparkleGoldHead } from "../src/fallback/canvas2dRain.ts";

describe("Canvas2D gold sparkle", () => {
  it("only samples and accepts the sparkle roll for gold", () => {
    const sparkling = vi.fn(() => 0.049);
    expect(shouldSparkleGoldHead("gold", sparkling)).toBe(true);
    expect(sparkling).toHaveBeenCalledOnce();

    const nonGold = vi.fn(() => 0);
    expect(shouldSparkleGoldHead("amber", nonGold)).toBe(false);
    expect(nonGold).not.toHaveBeenCalled();
  });

  it("keeps rolls at or above the five-percent threshold unlit", () => {
    expect(shouldSparkleGoldHead("gold", () => 0.05)).toBe(false);
  });
});
