import { describe, it, expect } from "vitest";
import {
  computeTimeline,
  cursorVisible,
  totalDuration,
  DEFAULT_SCRIPT,
  DEFAULT_TYPE_CONFIG,
  type MessageLine,
  type TypeConfig,
} from "../src/sim/messageOverlay.ts";

const LINES: MessageLine[] = [{ text: "AB" }, { text: "CDE" }];
const CFG: TypeConfig = {
  charMs: 100,
  holdMs: 500,
  startDelayMs: 200,
  fadeOutMs: 400,
  blinkMs: 450,
};

describe("computeTimeline", () => {
  it("shows nothing during the start delay", () => {
    const s = computeTimeline(LINES, CFG, 100);
    expect(s.visibleText).toBe("");
    expect(s.done).toBe(false);
  });

  it("types the first line character by character", () => {
    // start delay 200, then 100ms/char
    expect(computeTimeline(LINES, CFG, 200).visibleText).toBe("");
    expect(computeTimeline(LINES, CFG, 200 + 100).visibleText).toBe("A");
    expect(computeTimeline(LINES, CFG, 200 + 150).visibleText).toBe("A");
    expect(computeTimeline(LINES, CFG, 200 + 200).visibleText).toBe("AB");
  });

  it("holds, then advances to the second line", () => {
    // line 1 typed at +200, held for 500 -> clears at +700, then types line 2
    const afterHold = 200 + 200 + 500 + 100; // first char of line 2
    expect(computeTimeline(LINES, CFG, afterHold).lineIndex).toBe(1);
    expect(computeTimeline(LINES, CFG, afterHold).visibleText).toBe("C");
  });

  it("fades out and finishes after the last line", () => {
    const total = totalDuration(LINES, CFG);
    expect(computeTimeline(LINES, CFG, total + 1).done).toBe(true);
    expect(computeTimeline(LINES, CFG, total + 1).opacity).toBe(0);
    // partway through fade-out, opacity is between 0 and 1
    const mid = total - CFG.fadeOutMs / 2;
    const s = computeTimeline(LINES, CFG, mid);
    expect(s.opacity).toBeGreaterThan(0);
    expect(s.opacity).toBeLessThan(1);
  });

  it("handles an empty script", () => {
    expect(computeTimeline([], CFG, 0).done).toBe(true);
  });
});

describe("cursor + duration", () => {
  it("blinks on a fixed period", () => {
    expect(cursorVisible(CFG, 0)).toBe(true);
    expect(cursorVisible(CFG, CFG.blinkMs)).toBe(false);
    expect(cursorVisible(CFG, CFG.blinkMs * 2)).toBe(true);
  });

  it("computes a positive total duration for the default script", () => {
    expect(totalDuration(DEFAULT_SCRIPT, DEFAULT_TYPE_CONFIG)).toBeGreaterThan(0);
  });
});
