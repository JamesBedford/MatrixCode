import { describe, expect, it } from "vitest";
import { ImageScheduler, imageHash, imageUnit } from "../src/sim/imageScheduler.ts";
import type { ImagesDoc } from "../src/types.ts";

const doc = (over: Partial<ImagesDoc> = {}): ImagesDoc => ({
  images: [{ name: "A", width: 1, height: 1, data: "/w==" }],
  enabled: true,
  frequencyMs: 1000,
  persistenceMs: 1000,
  appearMs: 400,
  disappearMs: 600,
  flickerOut: true,
  brightnessFade: true,
  imageScale: 0.72,
  imagePlacementJitter: 0.35,
  ...over,
});

describe("ImageScheduler", () => {
  it("locks the native integer hash", () => {
    expect(imageHash(0)).toBe(0);
    expect(imageHash(0x12345678)).toBe(4125564054);
    expect(imageUnit(0x12345678)).toBeCloseTo(0.9027799368, 9);
  });

  it("previews immediately with the full appear/hold/disappear envelope", () => {
    const scheduler = new ImageScheduler({ seed: 7, epochMs: 0 });
    expect(scheduler.previewOne(100, doc())!.intensity).toBe(0);
    expect(scheduler.update(300)!.intensity).toBeCloseTo(0.5);
    expect(scheduler.update(500)!.intensity).toBe(1);
    expect(scheduler.update(1700)!.intensity).toBeCloseTo(2 / 3);
    expect(scheduler.update(2100)).toBeNull();
  });

  it("keeps synchronized panels byte-for-byte aligned across late updates", () => {
    const a = new ImageScheduler({ seed: 0x13579, epochMs: 10_000, synchronized: true });
    const b = new ImageScheduler({ seed: 0x13579, epochMs: 10_000, synchronized: true });
    a.configure(doc({ appearMs: 0, disappearMs: 0 }), 10_000);
    b.configure(doc({ appearMs: 0, disappearMs: 0 }), 10_000);
    // The first deterministic activation begins 0.75â€“1.25 seconds after the epoch and lasts one
    // second, so both samples are guaranteed to be inside that same reveal.
    const frameA = a.update(11_500);
    const frameB = b.update(11_637);
    expect(frameA?.image.name).toBe(frameB?.image.name);
    expect(frameA?.placementX).toBe(frameB?.placementX);
    expect(frameA?.placementY).toBe(frameB?.placementY);
    expect(frameA?.animationBucket).not.toBe(frameB?.animationBucket);
  });

  it("fast-forwards a newly attached synchronized panel without replaying expired reveals", () => {
    const epochMs = 10_000;
    const targetMs = epochMs + 60_000;
    const playlist = doc({
      images: [
        { name: "A", width: 1, height: 1, data: "/w==" },
        { name: "B", width: 1, height: 1, data: "gA==" },
      ],
      frequencyMs: 500,
      persistenceMs: 500,
      appearMs: 100,
      disappearMs: 100,
    });
    const reference = new ImageScheduler({ seed: 0x2468ac, epochMs, synchronized: true });
    reference.configure(playlist, epochMs);
    for (let now = epochMs; now <= targetMs; now += 100) reference.update(now);

    const late = new ImageScheduler({ seed: 0x2468ac, epochMs, synchronized: true });
    late.configure(playlist, targetMs);
    expect(late.update(targetMs)).toEqual(reference.update(targetMs));
    expect(late.update(targetMs + 16)).toEqual(reference.update(targetMs + 16));
  });

  it("deterministically bounds a hostile synchronized epoch", () => {
    const targetMs = 1_000_000_000_900;
    const playlist = doc({
      frequencyMs: 500,
      persistenceMs: 500,
      appearMs: 0,
      disappearMs: 0,
    });
    const first = new ImageScheduler({ seed: 0x13579bdf, epochMs: 0, synchronized: true });
    const second = new ImageScheduler({ seed: 0x13579bdf, epochMs: 0, synchronized: true });
    first.configure(playlist, targetMs);
    second.configure(playlist, targetMs);

    expect(first.update(targetMs)).toEqual(second.update(targetMs));
    expect(first.update(targetMs + 1500)).toEqual(second.update(targetMs + 1500));
  });

  it("shifts an active normal timeline across pause without catch-up", () => {
    const scheduler = new ImageScheduler({ seed: 1, epochMs: 0 });
    scheduler.previewOne(100, doc({ appearMs: 0, disappearMs: 0, persistenceMs: 1000 }));
    scheduler.shiftTimelineBy(5000);
    expect(scheduler.update(5500)).not.toBeNull();
    expect(scheduler.update(6100)).toBeNull();
  });
});
