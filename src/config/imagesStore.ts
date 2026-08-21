import type { ImageMask, ImagesDoc } from "../types.ts";
import { bool, num, text } from "./sanitize.ts";
import { nativeStorageDidChange } from "../platform/nativeHost.ts";

export const IMAGES_STORAGE_KEY = "mx-images";
export const MAX_IMAGES = 64;
export const MAX_IMAGE_DIMENSION = 96;
export const MAX_IMAGE_NAME_LENGTH = 80;
export const MAX_IMAGE_BASE64_LENGTH = 49152;

const MAX_MS = 600000;

export const DEFAULT_IMAGES: ImagesDoc = {
  images: [],
  enabled: false,
  frequencyMs: 14000,
  persistenceMs: 12000,
  appearMs: 4500,
  disappearMs: 4500,
  flickerOut: true,
  brightnessFade: false,
  imageScale: 0.72,
  imagePlacementJitter: 0.35,
};

export function cloneImages(doc: ImagesDoc): ImagesDoc {
  return { ...doc, images: doc.images.map((image) => ({ ...image })) };
}

/** Return the decoded byte length for strict padded Base64, or -1 when malformed. */
export function base64ByteLength(value: string): number {
  if (value.length === 0 || value.length % 4 !== 0) return -1;
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) return -1;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  return (value.length / 4) * 3 - padding;
}

export function decodeBase64Mask(value: string): Uint8Array | null {
  const length = base64ByteLength(value);
  if (length < 0) return null;
  try {
    const binary = atob(value);
    if (binary.length !== length) return null;
    const bytes = new Uint8Array(length);
    for (let i = 0; i < length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

export function encodeBase64Mask(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x2000) {
    binary += String.fromCharCode(...bytes.subarray(i, Math.min(bytes.length, i + 0x2000)));
  }
  return btoa(binary);
}

/** Sanitize one portable mask. Numeric dimensions are truncated after clamping, matching native. */
export function sanitizeImageMask(raw: unknown): ImageMask | null {
  if (typeof raw !== "object" || raw === null) return null;
  const item = raw as Record<string, unknown>;
  if (typeof item.width !== "number" || !Number.isFinite(item.width)) return null;
  if (typeof item.height !== "number" || !Number.isFinite(item.height)) return null;
  const width = Math.trunc(Math.min(MAX_IMAGE_DIMENSION, Math.max(1, item.width)));
  const height = Math.trunc(Math.min(MAX_IMAGE_DIMENSION, Math.max(1, item.height)));
  if (typeof item.data !== "string") return null;
  const data = item.data.slice(0, MAX_IMAGE_BASE64_LENGTH);
  if (base64ByteLength(data) !== width * height) return null;
  const trimmed = text(item.name, MAX_IMAGE_NAME_LENGTH, "Image").trim();
  return { name: trimmed || "Image", width, height, data };
}

/** Coerce arbitrary JSON into the cross-platform image document. */
export function sanitizeImages(raw: unknown): ImagesDoc {
  const value = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const images: ImageMask[] = [];
  if (Array.isArray(value.images)) {
    for (const candidate of value.images) {
      const image = sanitizeImageMask(candidate);
      if (image) images.push(image);
      if (images.length === MAX_IMAGES) break;
    }
  }
  return {
    images,
    enabled: bool(value.enabled, DEFAULT_IMAGES.enabled),
    frequencyMs: num(value.frequencyMs, 500, MAX_MS, DEFAULT_IMAGES.frequencyMs),
    persistenceMs: num(value.persistenceMs, 500, MAX_MS, DEFAULT_IMAGES.persistenceMs),
    appearMs: num(value.appearMs, 0, MAX_MS, DEFAULT_IMAGES.appearMs),
    disappearMs: num(value.disappearMs, 0, MAX_MS, DEFAULT_IMAGES.disappearMs),
    flickerOut: bool(value.flickerOut, DEFAULT_IMAGES.flickerOut),
    brightnessFade: bool(value.brightnessFade, DEFAULT_IMAGES.brightnessFade),
    imageScale: num(value.imageScale, 0.05, 1, DEFAULT_IMAGES.imageScale),
    imagePlacementJitter: num(
      value.imagePlacementJitter,
      0,
      1,
      DEFAULT_IMAGES.imagePlacementJitter,
    ),
  };
}

/** localStorage-backed image playlist. */
export class ImagesStore {
  private doc: ImagesDoc;

  constructor(
    private readonly storage: Storage | null = defaultStorage(),
    initial?: ImagesDoc,
  ) {
    this.doc = initial === undefined ? this.load() : sanitizeImages(initial);
  }

  private load(): ImagesDoc {
    try {
      const raw = this.storage?.getItem(IMAGES_STORAGE_KEY);
      return raw ? sanitizeImages(JSON.parse(raw) as unknown) : cloneImages(DEFAULT_IMAGES);
    } catch {
      return cloneImages(DEFAULT_IMAGES);
    }
  }

  get(): ImagesDoc {
    return cloneImages(this.doc);
  }

  set(doc: ImagesDoc): void {
    this.doc = sanitizeImages(doc);
    try {
      const value = JSON.stringify(this.doc);
      this.storage?.setItem(IMAGES_STORAGE_KEY, value);
      if (this.storage) nativeStorageDidChange(IMAGES_STORAGE_KEY, value);
    } catch {
      // Keep the sanitized in-memory playlist if persistent storage is unavailable/full.
    }
  }

  reset(): ImagesDoc {
    this.doc = cloneImages(DEFAULT_IMAGES);
    try {
      this.storage?.removeItem(IMAGES_STORAGE_KEY);
      if (this.storage) nativeStorageDidChange(IMAGES_STORAGE_KEY, null);
    } catch {
      // Ignore unavailable storage.
    }
    return this.get();
  }
}

function defaultStorage(): Storage | null {
  try {
    return globalThis.localStorage;
  } catch {
    return null;
  }
}
