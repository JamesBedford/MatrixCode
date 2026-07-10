import { describe, it, expect } from "vitest";
import { MessageScheduler } from "../src/sim/messageScheduler.ts";
import { createGlyphSet } from "../src/sim/glyphSet.ts";
import { createRng } from "../src/util/rng.ts";
import type { MessagesDoc } from "../src/types.ts";

// A minimal stand-in for RainSim that records what the scheduler asks of it.
class FakeSim {
  cols: number;
  rows: number;
  last: Map<number, number> | null = null;
  sets = 0;
  updates = 0;
  cleared = 0;
  intensity = 1;
  scramble = 0;
  constructor(cols: number, rows: number) {
    this.cols = cols;
    this.rows = rows;
  }
  setMessageTargets(t: Map<number, number>): void {
    this.last = new Map(t);
    this.sets++;
  }
  updateMessageTargets(t: Map<number, number>): void {
    this.last = new Map(t);
    this.updates++;
  }
  clearMessageTargets(): void {
    this.last = null;
    this.cleared++;
    this.intensity = 1;
    this.scramble = 0;
  }
  setMessageIntensity(v: number): void {
    this.intensity = v;
  }
  setMessageScramble(v: number): void {
    this.scramble = v;
  }
}

const glyphSet = createGlyphSet();
const doc = (over: Partial<MessagesDoc> = {}): MessagesDoc => ({
  messages: ["HELLO"],
  enabled: true,
  frequencyMs: 1000,
  persistenceMs: 500,
  appearMs: 0,
  disappearMs: 0,
  flickerOut: false,
  brightnessFade: true,
  verticalPosition: 0.475,
  verticalJitter: 0.25,
  ...over,
});
const sched = (seed = 1): MessageScheduler => new MessageScheduler({ glyphSet, rng: createRng(seed) });
const rowOf = (m: Map<number, number>, cols: number): number => Math.floor([...m.keys()][0]! / cols);

describe("MessageScheduler.fire (via previewOne)", () => {
  it("centers a message horizontally and maps chars to glyph indices", () => {
    const s = sched();
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["AB"] }));
    expect(sim.last).not.toBeNull();
    const row = rowOf(sim.last!, 20);
    // width 2 → startCol = floor((20-2)/2) = 9
    expect(sim.last!.size).toBe(2);
    expect(sim.last!.get(row * 20 + 9)).toBe(glyphSet.charToGlyphIndex("A"));
    expect(sim.last!.get(row * 20 + 10)).toBe(glyphSet.charToGlyphIndex("B"));
  });

  it("centers one message across the whole virtual grid when no regions are supplied", () => {
    const s = sched();
    const sim = new FakeSim(90, 40);
    s.previewOne(0, sim, doc({ messages: ["AB"], verticalJitter: 0 }));
    expect(sim.last!.size).toBe(2);
    const row = rowOf(sim.last!, 90);
    expect(sim.last!.get(row * 90 + 44)).toBe(glyphSet.charToGlyphIndex("A"));
    expect(sim.last!.get(row * 90 + 45)).toBe(glyphSet.charToGlyphIndex("B"));
  });

  it("centers a copy within every display region when regions are supplied", () => {
    const s = sched();
    const sim = new FakeSim(90, 40);
    const regions = [
      { colStart: 0, rowStart: 0, cols: 30, rows: 40 },
      { colStart: 30, rowStart: 0, cols: 30, rows: 40 },
      { colStart: 60, rowStart: 0, cols: 30, rows: 40 },
    ];
    s.previewOne(0, sim, doc({ messages: ["AB"], verticalPosition: 0.5, verticalJitter: 0 }), regions);
    expect(sim.last!.size).toBe(6);
    for (const startCol of [14, 44, 74]) {
      expect(sim.last!.get(20 * 90 + startCol)).toBe(glyphSet.charToGlyphIndex("A"));
      expect(sim.last!.get(20 * 90 + startCol + 1)).toBe(glyphSet.charToGlyphIndex("B"));
    }
  });

  it("applies vertical position and jitter relative to each display region", () => {
    const s = sched(8);
    const sim = new FakeSim(60, 80);
    const regions = [
      { colStart: 0, rowStart: 0, cols: 30, rows: 30 },
      { colStart: 30, rowStart: 40, cols: 30, rows: 40 },
    ];
    s.previewOne(0, sim, doc({ messages: ["A"], verticalPosition: 0.5, verticalJitter: 0.5 }), regions);
    const rows = [...sim.last!.keys()].map((idx) => Math.floor(idx / sim.cols));
    expect(rows[0]).toBeGreaterThanOrEqual(7);
    expect(rows[0]).toBeLessThanOrEqual(22);
    expect(rows[1]).toBeGreaterThanOrEqual(49);
    expect(rows[1]).toBeLessThanOrEqual(70);
  });

  it("places the row within the middle vertical band", () => {
    for (let seed = 1; seed <= 8; seed++) {
      const s = sched(seed);
      const sim = new FakeSim(20, 40);
      s.previewOne(0, sim, doc({ messages: ["AB"] }));
      const row = rowOf(sim.last!, 20);
      expect(row).toBeGreaterThanOrEqual(Math.floor(40 * 0.35));
      expect(row).toBeLessThanOrEqual(Math.floor(40 * 0.6));
    }
  });

  it("honours the vertical position anchor (0 = top, 1 = bottom) with no jitter", () => {
    const top = sched(); const simTop = new FakeSim(20, 40);
    top.previewOne(0, simTop, doc({ messages: ["AB"], verticalPosition: 0, verticalJitter: 0 }));
    expect(rowOf(simTop.last!, 20)).toBe(0);

    const bottom = sched(); const simBottom = new FakeSim(20, 40);
    bottom.previewOne(0, simBottom, doc({ messages: ["AB"], verticalPosition: 1, verticalJitter: 0 }));
    expect(rowOf(simBottom.last!, 20)).toBe(39);
  });

  it("keeps the message on screen even at the extremes with full jitter", () => {
    for (const verticalPosition of [0, 0.5, 1]) {
      for (let seed = 1; seed <= 12; seed++) {
        const s = sched(seed);
        const sim = new FakeSim(20, 40);
        s.previewOne(0, sim, doc({ messages: ["AB"], verticalPosition, verticalJitter: 1 }));
        const row = rowOf(sim.last!, 20);
        expect(row).toBeGreaterThanOrEqual(0);
        expect(row).toBeLessThanOrEqual(39);
      }
    }
  });

  it("leaves a gap for internal spaces, keeping later letters aligned", () => {
    const s = sched();
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["A B"] })); // width 3 → startCol 8
    const row = rowOf(sim.last!, 20);
    expect(sim.last!.size).toBe(2);
    expect(sim.last!.get(row * 20 + 8)).toBe(glyphSet.charToGlyphIndex("A"));
    expect(sim.last!.get(row * 20 + 9)).toBeUndefined(); // space → no target
    expect(sim.last!.get(row * 20 + 10)).toBe(glyphSet.charToGlyphIndex("B"));
  });

  it("renders lowercase and punctuation (message-only glyphs)", () => {
    const s = sched();
    const sim = new FakeSim(30, 40);
    s.previewOne(0, sim, doc({ messages: ["a!"] }));
    const vals = [...sim.last!.values()].sort((x, y) => x - y);
    expect(vals).toEqual([glyphSet.charToGlyphIndex("a"), glyphSet.charToGlyphIndex("!")].sort((x, y) => x! - y!));
  });

  it("skips a message wider than the grid without setting targets", () => {
    const s = sched();
    const sim = new FakeSim(6, 20);
    s.previewOne(0, sim, doc({ messages: ["TOOLONGWORD"] }));
    expect(sim.sets).toBe(0);
    expect(sim.last).toBeNull();
  });

  it("skips an all-unsupported message without setting targets", () => {
    const s = sched();
    const sim = new FakeSim(30, 40);
    s.previewOne(0, sim, doc({ messages: ["@#$"] }));
    expect(sim.sets).toBe(0);
  });
});

describe("MessageScheduler.update scheduling", () => {
  it("fires after the frequency gap and clears after persistence", () => {
    const s = sched(5);
    const sim = new FakeSim(30, 40);
    s.configure(doc({ messages: ["HI"], frequencyMs: 1000, persistenceMs: 500 }));
    s.update(0, sim); // arm; gap ∈ [750, 1250)
    s.update(700, sim);
    expect(sim.sets).toBe(0); // before the earliest possible fire
    s.update(1300, sim);
    expect(sim.sets).toBe(1); // after the latest possible fire
    expect(sim.last).not.toBeNull();
    // activeUntil = fireTime(1300) + persistence(500) = 1800
    s.update(1700, sim);
    expect(sim.last).not.toBeNull();
    s.update(1900, sim);
    expect(sim.last).toBeNull();
    expect(sim.cleared).toBeGreaterThanOrEqual(1);
  });

  it("shows one message at a time", () => {
    const s = sched(3);
    const sim = new FakeSim(30, 40);
    s.configure(doc({ messages: ["HI", "NEO"], frequencyMs: 200, persistenceMs: 1000 }));
    let maxActive = 0;
    for (let t = 0; t <= 3000; t += 25) {
      s.update(t, sim);
      if (sim.last) maxActive = Math.max(maxActive, 1);
    }
    expect(sim.sets).toBeGreaterThan(0);
    expect(maxActive).toBe(1); // never more than one active map
  });

  it("never fires when disabled, and clears an active message if disabled mid-flight", () => {
    const s = sched();
    const sim = new FakeSim(30, 40);
    s.previewOne(0, sim, doc({ messages: ["HI"], persistenceMs: 100000 }));
    expect(sim.last).not.toBeNull();
    s.configure(doc({ enabled: false }));
    for (let t = 1; t < 5000; t += 100) s.update(t, sim);
    expect(sim.last).toBeNull();
    expect(sim.sets).toBe(1); // only the preview ever set targets
  });

  it("never fires with an empty or whitespace-only message pool", () => {
    const s = sched();
    const sim = new FakeSim(30, 40);
    s.configure(doc({ messages: ["   ", ""], frequencyMs: 100, persistenceMs: 100 }));
    for (let t = 0; t < 5000; t += 50) s.update(t, sim);
    expect(sim.sets).toBe(0);
  });

  it("re-lays out an active message when the grid is resized", () => {
    const s = sched(7);
    const sim = new FakeSim(30, 40);
    s.previewOne(0, sim, doc({ messages: ["HI"], persistenceMs: 100000 }));
    expect(sim.last).not.toBeNull();
    const setsBeforeResize = sim.sets;
    // Simulate a resize: sim drops its own targets, dims change.
    sim.clearMessageTargets();
    sim.cols = 50;
    sim.rows = 60;
    s.update(10, sim);
    expect(sim.last).not.toBeNull();
    expect(sim.sets).toBe(setsBeforeResize + 1);
    const row = rowOf(sim.last!, 50);
    expect(sim.last!.get(row * 50 + 24)).toBe(glyphSet.charToGlyphIndex("H"));
    expect(sim.last!.get(row * 50 + 25)).toBe(glyphSet.charToGlyphIndex("I"));
  });

  it("ends an active message cleanly if it no longer fits after a resize", () => {
    const s = sched(7);
    const sim = new FakeSim(30, 40);
    s.previewOne(0, sim, doc({ messages: ["A MESSAGE"], persistenceMs: 100000 }));
    sim.clearMessageTargets();
    sim.cols = 4;
    sim.rows = 20;
    s.update(10, sim);
    expect(sim.last).toBeNull();
  });

  it("is deterministic for a given seed and clock", () => {
    const a = sched(99);
    const b = sched(99);
    const simA = new FakeSim(30, 40);
    const simB = new FakeSim(30, 40);
    const d = doc({ messages: ["MATRIX", "NEO", "WAKE UP"], frequencyMs: 500, persistenceMs: 300 });
    a.configure(d);
    b.configure(d);
    for (let t = 0; t <= 10000; t += 50) {
      a.update(t, simA);
      b.update(t, simB);
    }
    expect(simA.sets).toBe(simB.sets);
    const ea = simA.last ? [...simA.last.entries()] : null;
    const eb = simB.last ? [...simB.last.entries()] : null;
    expect(ea).toEqual(eb);
  });

  it("previewOne fires immediately regardless of the schedule", () => {
    const s = sched();
    const sim = new FakeSim(30, 40);
    s.configure(doc({ frequencyMs: 100000 })); // would not fire for a long time
    s.previewOne(5, sim, doc({ messages: ["NEO"] }));
    expect(sim.last).not.toBeNull();
  });
});

describe("MessageScheduler token resolution + live ticking", () => {
  const schedWith = (resolveText: (raw: string) => string, seed = 1): MessageScheduler =>
    new MessageScheduler({ glyphSet, rng: createRng(seed), resolveText });

  it("resolves a message through resolveText before laying it out", () => {
    const s = schedWith(() => "AB"); // whatever the raw pool holds, it renders "AB"
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["{whatever}"] }));
    expect(sim.last).not.toBeNull();
    const row = rowOf(sim.last!, 20);
    expect(sim.last!.size).toBe(2); // width 2 → startCol 9
    expect(sim.last!.get(row * 20 + 9)).toBe(glyphSet.charToGlyphIndex("A"));
    expect(sim.last!.get(row * 20 + 10)).toBe(glyphSet.charToGlyphIndex("B"));
  });

  it("re-lays-out via updateMessageTargets when the resolved text ticks, without re-firing setMessageTargets", () => {
    let n = 0;
    const s = schedWith(() => `T${n}`);
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["m"], persistenceMs: 100000, appearMs: 0, disappearMs: 0 }));
    expect(sim.sets).toBe(1);
    expect(sim.updates).toBe(0);

    s.update(1000, sim);
    expect(sim.updates).toBe(0); // resolved text unchanged ("T0") → no re-layout

    n = 1; // a placeholder ticked
    s.update(2000, sim);
    expect(sim.updates).toBe(1); // re-laid out in place
    expect(sim.sets).toBe(1); // never re-set from scratch
    const row = rowOf(sim.last!, 20);
    expect(sim.last!.get(row * 20 + 9)).toBe(glyphSet.charToGlyphIndex("T"));
    expect(sim.last!.get(row * 20 + 10)).toBe(glyphSet.charToGlyphIndex("1"));
  });

  it("keeps the row fixed across a re-layout so the message never jumps", () => {
    let n = 0;
    const s = schedWith(() => `T${n}`, 4);
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["m"], persistenceMs: 100000, appearMs: 0, disappearMs: 0 }));
    const rowBefore = rowOf(sim.last!, 20);
    n = 2;
    s.update(1000, sim);
    expect(rowOf(sim.last!, 20)).toBe(rowBefore);
  });

  it("with the default identity resolver, an active message never re-lays-out", () => {
    const s = sched();
    const sim = new FakeSim(20, 40);
    s.previewOne(0, sim, doc({ messages: ["AB"], persistenceMs: 100000, appearMs: 0, disappearMs: 0 }));
    for (let t = 100; t < 5000; t += 100) s.update(t, sim);
    expect(sim.updates).toBe(0);
    expect(sim.sets).toBe(1);
  });
});

describe("MessageScheduler fade envelope", () => {
  it("ramps 0→1 over appearMs, holds for persistenceMs, then 1→0 over disappearMs", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    // appear 400 + hold 2000 + disappear 600 = 3000 total; fade-out begins at 2400
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 2000, appearMs: 400, disappearMs: 600 }));
    expect(sim.intensity).toBeCloseTo(0, 5); // fade-in start
    s.update(200, sim);
    expect(sim.intensity).toBeCloseTo(0.5, 2); // mid fade-in
    s.update(400, sim);
    expect(sim.intensity).toBeCloseTo(1, 5); // fade-in complete
    s.update(1500, sim);
    expect(sim.intensity).toBe(1); // hold
    s.update(2400, sim);
    expect(sim.intensity).toBeCloseTo(1, 5); // hold end / fade-out start
    s.update(2700, sim);
    expect(sim.intensity).toBeCloseTo(0.5, 2); // mid fade-out
    s.update(2999, sim);
    expect(sim.intensity).toBeLessThan(0.05); // nearly gone
    s.update(3000, sim);
    expect(sim.last).toBeNull(); // expired and cleared
  });

  it("holds at 1 with no fades, ending after persistenceMs", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 0, disappearMs: 0 }));
    expect(sim.intensity).toBe(1);
    s.update(500, sim);
    expect(sim.intensity).toBe(1);
    s.update(999, sim);
    expect(sim.intensity).toBe(1);
    s.update(1000, sim);
    expect(sim.last).toBeNull();
  });

  it("extends the total animation by the fades instead of scaling them down", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    // hold 1000 + fades 2000 each = 5000 total; the fades run their full length, never clipped
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 2000, disappearMs: 2000 }));
    s.update(1000, sim);
    expect(sim.intensity).toBeCloseTo(0.5, 2); // still fading in at 1s (appear runs the full 2s)
    expect(sim.last).not.toBeNull();
    s.update(2500, sim);
    expect(sim.intensity).toBe(1); // hold (2000..3000)
    s.update(4000, sim);
    expect(sim.intensity).toBeCloseTo(0.5, 2); // mid fade-out (3000..5000)
    expect(sim.last).not.toBeNull(); // still active long past persistenceMs — no clipping
    s.update(5000, sim);
    expect(sim.last).toBeNull();
  });

  it("flickers the message in too — scramble ramps 1→0 over the fade-in", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    // appear 2000 + hold 1000 + disappear 2000; fade-in 0..2000
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 2000, disappearMs: 2000, flickerOut: true }));
    expect(sim.scramble).toBeCloseTo(1, 5); // starts fully random
    s.update(1000, sim);
    expect(sim.scramble).toBeCloseTo(0.5, 2); // mid fade-in
    s.update(2000, sim);
    expect(sim.scramble).toBeCloseTo(0, 5); // resolved to the letter
    s.update(2500, sim);
    expect(sim.scramble).toBe(0); // hold, no scramble
  });

  it("ramps the scramble 0→1 over the fade-out when flickerOut is enabled", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    // appear 0 + hold 1000 + disappear 2000 = 3000; fade-out 1000..3000
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 0, disappearMs: 2000, flickerOut: true }));
    s.update(500, sim);
    expect(sim.scramble).toBe(0); // during hold, no scramble
    s.update(1000, sim);
    expect(sim.scramble).toBeCloseTo(0, 5); // fade-out start
    s.update(2000, sim);
    expect(sim.scramble).toBeCloseTo(0.5, 2); // mid fade-out
    s.update(2999, sim);
    expect(sim.scramble).toBeGreaterThan(0.95); // nearly fully random
  });

  it("keeps scramble at 0 when flickerOut is disabled", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 0, disappearMs: 2000, flickerOut: false }));
    s.update(2000, sim);
    expect(sim.scramble).toBe(0);
  });

  it("holds intensity at 1 when brightnessFade is disabled (no transparency fade)", () => {
    const s = sched();
    const sim = new FakeSim(40, 40);
    // Long fades, but brightnessFade off → no dimming at any point.
    s.previewOne(0, sim, doc({ messages: ["NEO"], persistenceMs: 1000, appearMs: 2000, disappearMs: 2000, brightnessFade: false }));
    expect(sim.intensity).toBe(1);
    s.update(1000, sim);
    expect(sim.intensity).toBe(1); // would be mid fade-in if enabled
    s.update(4000, sim);
    expect(sim.intensity).toBe(1); // would be mid fade-out if enabled
  });
});
