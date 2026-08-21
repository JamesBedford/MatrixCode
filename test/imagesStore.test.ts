import { describe, expect, it } from "vitest";
import {
  DEFAULT_IMAGES,
  ImagesStore,
  MAX_IMAGES,
  cloneImages,
  decodeBase64Mask,
  encodeBase64Mask,
  sanitizeImageMask,
  sanitizeImages,
} from "../src/config/imagesStore.ts";

class MemoryStorage implements Storage {
  private readonly values = new Map<string, string>();
  get length(): number { return this.values.size; }
  clear(): void { this.values.clear(); }
  getItem(key: string): string | null { return this.values.get(key) ?? null; }
  key(index: number): string | null { return [...this.values.keys()][index] ?? null; }
  removeItem(key: string): void { this.values.delete(key); }
  setItem(key: string, value: string): void { this.values.set(key, value); }
}

const image = (name = "Mask") => ({ name, width: 1, height: 1, data: "AA==" });

describe("portable image document", () => {
  it("strictly validates masks and normalizes names/dimensions", () => {
    expect(sanitizeImageMask({ name: "  ", width: -2, height: 1.9, data: "AA==" })).toEqual(image("Image"));
    expect(sanitizeImageMask({ name: "bad", width: 2, height: 2, data: "AA==" })).toBeNull();
    expect(sanitizeImageMask({ name: "bad", width: "1", height: 1, data: "AA==" })).toBeNull();
    expect(sanitizeImageMask({ name: "bad", width: 1, height: 1, data: "%%%=" })).toBeNull();
  });

  it("keeps the first 64 valid images rather than the first 64 raw entries", () => {
    const raw = Array.from({ length: 100 }, (_, index) => index % 3 === 0 ? null : image(String(index)));
    const clean = sanitizeImages({ images: raw });
    expect(clean.images).toHaveLength(MAX_IMAGES);
    expect(clean.images[0]!.name).toBe("1");
    expect(clean.images.at(-1)!.name).toBe("95");
  });

  it("clamps timing, scale, and booleans to the native contract", () => {
    const clean = sanitizeImages({
      frequencyMs: 1,
      persistenceMs: 999999,
      appearMs: -2,
      disappearMs: 999999,
      imageScale: 2,
      imagePlacementJitter: -1,
      enabled: "yes",
    });
    expect(clean).toMatchObject({
      frequencyMs: 500,
      persistenceMs: 600000,
      appearMs: 0,
      disappearMs: 600000,
      imageScale: 1,
      imagePlacementJitter: 0,
      enabled: false,
    });
  });

  it("round-trips strict Base64 bytes", () => {
    const bytes = new Uint8Array([0, 1, 127, 128, 254, 255]);
    expect(decodeBase64Mask(encodeBase64Mask(bytes))).toEqual(bytes);
    expect(decodeBase64Mask("AAAA=A==")).toBeNull();
  });

  it("deep clones and persists independently", () => {
    const storage = new MemoryStorage();
    const first = new ImagesStore(storage);
    const doc = cloneImages(DEFAULT_IMAGES);
    doc.images.push(image());
    doc.enabled = true;
    first.set(doc);
    doc.images[0]!.name = "mutated";
    expect(new ImagesStore(storage).get().images[0]!.name).toBe("Mask");
    expect(first.reset()).toEqual(DEFAULT_IMAGES);
  });
});
