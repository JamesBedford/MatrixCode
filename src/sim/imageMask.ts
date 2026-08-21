import type { ImageMask } from "../types.ts";
import {
  MAX_IMAGE_DIMENSION,
  MAX_IMAGE_NAME_LENGTH,
  encodeBase64Mask,
} from "../config/imagesStore.ts";

export interface RgbaImage {
  width: number;
  height: number;
  /** Top-to-bottom, straight-alpha sRGB RGBA8 bytes. */
  rgba: Uint8ClampedArray | Uint8Array;
}

export function imageMaskDimensions(width: number, height: number): { width: number; height: number } {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    throw new Error("Image dimensions must be positive and finite");
  }
  const scale = Math.min(1, MAX_IMAGE_DIMENSION / width, MAX_IMAGE_DIMENSION / height);
  return {
    width: Math.max(1, Math.min(MAX_IMAGE_DIMENSION, Math.round(width * scale))),
    height: Math.max(1, Math.min(MAX_IMAGE_DIMENSION, Math.round(height * scale))),
  };
}

/**
 * Convert already-resized straight-alpha sRGB pixels to the legacy native mask.
 * The extra alpha multiplication is deliberate: the original macOS path read premultiplied RGB and
 * multiplied by alpha once more. Keeping that alpha-squared edge treatment preserves its appearance.
 */
export function rgbaToMaskBytes(image: RgbaImage): Uint8Array {
  const { width, height, rgba } = image;
  if (
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width < 1 ||
    height < 1 ||
    width > MAX_IMAGE_DIMENSION ||
    height > MAX_IMAGE_DIMENSION ||
    rgba.length !== width * height * 4
  ) throw new Error("Invalid RGBA image buffer");

  const values = new Float64Array(width * height);
  let min = 1;
  let max = 0;
  for (let pixel = 0, offset = 0; pixel < values.length; pixel++, offset += 4) {
    const alpha = rgba[offset + 3]! / 255;
    const luminance =
      (0.2126 * (rgba[offset]! / 255) +
        0.7152 * (rgba[offset + 1]! / 255) +
        0.0722 * (rgba[offset + 2]! / 255)) *
      alpha *
      alpha;
    values[pixel] = luminance;
    min = Math.min(min, luminance);
    max = Math.max(max, luminance);
  }

  const normalize = max - min > 0.035;
  const range = max - min;
  const bytes = new Uint8Array(values.length);
  for (let i = 0; i < values.length; i++) {
    const value = normalize ? (values[i]! - min) / range : values[i]!;
    bytes[i] = Math.round(Math.pow(Math.min(1, Math.max(0, value)), 0.82) * 255);
  }
  return bytes;
}

export function imageMaskFromRgba(name: string, image: RgbaImage): ImageMask {
  const cleanName = name.slice(0, MAX_IMAGE_NAME_LENGTH).trim() || "Image";
  return {
    name: cleanName,
    width: image.width,
    height: image.height,
    data: encodeBase64Mask(rgbaToMaskBytes(image)),
  };
}

function sourceDimensions(source: CanvasImageSource): { width: number; height: number } {
  if (source instanceof HTMLImageElement) {
    return { width: source.naturalWidth, height: source.naturalHeight };
  }
  if (source instanceof HTMLVideoElement) {
    return { width: source.videoWidth, height: source.videoHeight };
  }
  const sized = source as { width?: number; height?: number };
  return { width: Number(sized.width ?? 0), height: Number(sized.height ?? 0) };
}

function sourceToMask(name: string, source: CanvasImageSource): ImageMask {
  const dimensions = sourceDimensions(source);
  const target = imageMaskDimensions(dimensions.width, dimensions.height);
  const canvas = document.createElement("canvas");
  canvas.width = target.width;
  canvas.height = target.height;
  const context = canvas.getContext("2d", { willReadFrequently: true });
  if (!context) throw new Error("Canvas2D is unavailable for image import");
  context.imageSmoothingEnabled = true;
  context.imageSmoothingQuality = "high";
  context.clearRect(0, 0, target.width, target.height);
  context.drawImage(source, 0, 0, target.width, target.height);
  const rgba = context.getImageData(0, 0, target.width, target.height).data;
  return imageMaskFromRgba(name, { ...target, rgba });
}

function nameWithoutExtension(name: string): string {
  const base = name.replace(/^.*[\\/]/, "");
  const dot = base.lastIndexOf(".");
  return (dot > 0 ? base.slice(0, dot) : base).slice(0, MAX_IMAGE_NAME_LENGTH).trim() || "Image";
}

async function imageElementForUrl(url: string): Promise<HTMLImageElement> {
  return await new Promise((resolve, reject) => {
    const image = new Image();
    image.decoding = "async";
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error("Unsupported or corrupt image"));
    image.src = url;
  });
}

/** Decode the first still frame of an image URL into a portable mask. */
export async function imageUrlToMask(url: string, displayName = url): Promise<ImageMask> {
  const image = await imageElementForUrl(url);
  return sourceToMask(nameWithoutExtension(displayName), image);
}

/** Decode a browser-selected image file into the same compact document used by native hosts. */
export async function imageFileToMask(file: File): Promise<ImageMask> {
  if (!file.type.startsWith("image/") && !/\.(?:png|jpe?g|gif|bmp|tiff?|heic)$/i.test(file.name)) {
    throw new Error("Unsupported image type");
  }
  if (typeof createImageBitmap === "function") {
    const bitmap = await createImageBitmap(file, { imageOrientation: "from-image", premultiplyAlpha: "none" });
    try {
      return sourceToMask(nameWithoutExtension(file.name), bitmap);
    } finally {
      bitmap.close();
    }
  }
  const url = URL.createObjectURL(file);
  try {
    return await imageUrlToMask(url, file.name);
  } finally {
    URL.revokeObjectURL(url);
  }
}

/** Decode files in selection order, skipping bad inputs and respecting the portable playlist cap. */
export async function imageFilesToMasks(files: Iterable<File>, limit: number): Promise<ImageMask[]> {
  const masks: ImageMask[] = [];
  for (const file of files) {
    if (masks.length >= limit) break;
    try {
      masks.push(await imageFileToMask(file));
    } catch {
      // A corrupt/unsupported file must not disable the rest of the playlist or the rain.
    }
  }
  return masks;
}
