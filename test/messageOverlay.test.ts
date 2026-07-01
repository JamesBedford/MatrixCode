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

const LINES: MessageLine[] = [
  { text: "AB", holdMs: 500, pauseMs: 0 },
  { text: "CDE", holdMs: 500, pauseMs: 0 },
];
const CFG: TypeConfig = {
  charMs: 100,
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
    expect(computeTimeline(LINES, CFG, 200).visibleText).toBe("");
    expect(computeTimeline(LINES, CFG, 200 + 100).visibleText).toBe("A");
    expect(computeTimeline(LINES, CFG, 200 + 150).visibleText).toBe("A");
    expect(computeTimeline(LINES, CFG, 200 + 200).visibleText).toBe("AB");
  });

  it("holds, then advances to the second line (no pause)", () => {
    const afterHold = 200 + 200 + 500 + 100; // first char of line 2
    expect(computeTimeline(LINES, CFG, afterHold).lineIndex).toBe(1);
    expect(computeTimeline(LINES, CFG, afterHold).visibleText).toBe("C");
  });

  it("uses each line's own hold duration", () => {
    const lines: MessageLine[] = [
      { text: "A", holdMs: 100, pauseMs: 0 },
      { text: "B", holdMs: 100, pauseMs: 0 },
    ];
    // start 200; type A ends 300; hold 100 ends 400; type B ends 500
    expect(computeTimeline(lines, CFG, 450).lineIndex).toBe(1);
    expect(computeTimeline(lines, CFG, 350).lineIndex).toBe(0);
    expect(computeTimeline(lines, CFG, 350).visibleText).toBe("A");
  });

  it("shows a blank gap during a line's pause, then types the next line", () => {
    const lines: MessageLine[] = [
      { text: "A", holdMs: 200, pauseMs: 300 },
      { text: "B", holdMs: 200, pauseMs: 0 },
    ];
    // start 200; type A ends 300; hold 200 ends 500; pause 300 ends 800; type B from 800
    expect(computeTimeline(lines, CFG, 400).visibleText).toBe("A"); // mid-hold
    const pausing = computeTimeline(lines, CFG, 600); // mid-pause
    expect(pausing.visibleText).toBe("");
    expect(pausing.lineIndex).toBe(0);
    expect(pausing.opacity).toBe(1);
    expect(computeTimeline(lines, CFG, 850).visibleText).toBe(""); // 0 chars of B yet
    expect(computeTimeline(lines, CFG, 900).visibleText).toBe("B"); // B fully typed + holding
  });

  it("fades out and finishes after the last line", () => {
    const total = totalDuration(LINES, CFG);
    expect(computeTimeline(LINES, CFG, total + 1).done).toBe(true);
    expect(computeTimeline(LINES, CFG, total + 1).opacity).toBe(0);
    const mid = total - CFG.fadeOutMs / 2;
    const s = computeTimeline(LINES, CFG, mid);
    expect(s.opacity).toBeGreaterThan(0);
    expect(s.opacity).toBeLessThan(1);
  });

  it("handles an empty script", () => {
    expect(computeTimeline([], CFG, 0).done).toBe(true);
  });
});

describe("totalDuration", () => {
  it("ignores pauseMs on the last line", () => {
    const a: MessageLine[] = [{ text: "A", holdMs: 100, pauseMs: 5000 }];
    const b: MessageLine[] = [{ text: "A", holdMs: 100, pauseMs: 0 }];
    expect(totalDuration(a, CFG)).toBe(totalDuration(b, CFG));
  });

  it("includes inter-line pauses in the total duration", () => {
    const withPause: MessageLine[] = [
      { text: "A", holdMs: 100, pauseMs: 250 },
      { text: "B", holdMs: 100, pauseMs: 0 },
    ];
    const noPause: MessageLine[] = [
      { text: "A", holdMs: 100, pauseMs: 0 },
      { text: "B", holdMs: 100, pauseMs: 0 },
    ];
    expect(totalDuration(withPause, CFG) - totalDuration(noPause, CFG)).toBe(250);
  });

  it("computes a positive total duration for the default script", () => {
    expect(totalDuration(DEFAULT_SCRIPT, DEFAULT_TYPE_CONFIG)).toBeGreaterThan(0);
  });
});

describe("cursor", () => {
  it("blinks on a fixed period", () => {
    expect(cursorVisible(CFG, 0)).toBe(true);
    expect(cursorVisible(CFG, CFG.blinkMs)).toBe(false);
    expect(cursorVisible(CFG, CFG.blinkMs * 2)).toBe(true);
  });
});
