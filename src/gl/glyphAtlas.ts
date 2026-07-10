// Builds a monochrome glyph atlas texture from a 2D canvas. The film glyphs are
// MIRRORED half-width katakana, so mirroring is baked per-cell at build time
// (the single source of truth — there is no live shader flip). Glyphs the chosen
// font cannot render are detected and replaced with a visible fallback so the
// glyph-index order the simulation relies on never shifts.

export interface GlyphAtlas {
  texture: WebGLTexture;
  atlasCols: number;
  atlasRows: number;
  cellPx: number;
  glyphCount: number;
}

export interface AtlasOptions {
  chars: string[];
  /** CSS font-family stack with half-width katakana coverage. */
  fontFamily?: string;
  /** Atlas cell size in device px. */
  cellPx?: number;
  /** Bake a horizontal mirror into every glyph (the authentic look). */
  mirror: boolean;
  /** When mirroring, glyphs at this index and beyond are left UNMIRRORED (the readable message charset). */
  mirrorExcludeFrom?: number;
  /** Font weight. */
  weight?: number;
  /** Draw digit cells with explicit segment geometry instead of font outlines. */
  readableDigits?: boolean;
  /** Digit-only rain mode; remaps every ambient rain cell so old glyph states cannot leak through. */
  digitMode?: "binary" | "digits";
  /** Index where rain digit glyphs begin; supplied by the glyph set so atlas logic follows its order. */
  digitStart?: number;
}

const DEFAULT_FONT_STACK =
  '"Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic Pro", "Yu Gothic", "Meiryo", "MS Gothic", "Noto Sans JP", monospace';
const DEFAULT_DIGIT_START = 0xff9d - 0xff66 + 1;

/** Wait for fonts to be ready so the first draw isn't a fallback face. */
async function fontsReady(): Promise<void> {
  const fonts = (document as Document & { fonts?: FontFaceSet }).fonts;
  if (fonts?.ready) {
    try {
      await fonts.ready;
    } catch {
      /* ignore */
    }
  }
}

export async function buildGlyphAtlas(gl: WebGL2RenderingContext, opts: AtlasOptions): Promise<GlyphAtlas> {
  await fontsReady();

  const chars = opts.chars;
  const n = chars.length;
  const cellPx = opts.cellPx ?? 64;
  const atlasCols = Math.ceil(Math.sqrt(n));
  const atlasRows = Math.ceil(n / atlasCols);
  const fontFamily = opts.fontFamily ?? DEFAULT_FONT_STACK;
  const weight = opts.weight ?? 500;

  const texW = atlasCols * cellPx;
  const texH = atlasRows * cellPx;

  const canvas = document.createElement("canvas");
  canvas.width = texW;
  canvas.height = texH;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) throw new Error("2D context unavailable for glyph atlas");

  const fontPx = Math.round(cellPx * 0.78);
  ctx.font = `${weight} ${fontPx}px ${fontFamily}`;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#ffffff";

  const cellCenter = (i: number): [number, number] => {
    const cx = (i % atlasCols) * cellPx + cellPx / 2;
    const cy = Math.floor(i / atlasCols) * cellPx + cellPx / 2;
    return [cx, cy];
  };

  const mirrorExcludeFrom = opts.mirrorExcludeFrom ?? n; // by default nothing is excluded
  const digitMode = opts.digitMode;
  const digitStart = opts.digitStart ?? DEFAULT_DIGIT_START;
  const drawGlyph = (ch: string, i: number): void => {
    const displayChar = atlasDisplayCharForGlyphMode(ch, i, mirrorExcludeFrom, digitMode, digitStart);
    const [cx, cy] = cellCenter(i);
    ctx.save();
    ctx.translate(cx, cy);
    if (opts.mirror && i < mirrorExcludeFrom) ctx.scale(-1, 1); // message glyphs (>= cutoff) stay readable
    if ((opts.readableDigits || digitMode) && i < mirrorExcludeFrom && isDigit(displayChar)) {
      drawReadableDigit(ctx, displayChar, cellPx);
    } else {
      ctx.fillText(displayChar, 0, 0);
    }
    ctx.restore();
  };

  for (let i = 0; i < n; i++) drawGlyph(chars[i]!, i);

  // Coverage verification: any cell with no ink is a glyph the font lacks
  // (rendered as tofu/blank). Replace it with a known-good fallback so indices
  // stay valid. We scan the whole canvas once.
  const img = ctx.getImageData(0, 0, texW, texH).data;
  const cellInked = (i: number): boolean => {
    const x0 = (i % atlasCols) * cellPx;
    const y0 = Math.floor(i / atlasCols) * cellPx;
    for (let y = y0; y < y0 + cellPx; y += 2) {
      let row = (y * texW + x0) * 4;
      for (let x = 0; x < cellPx; x += 2) {
        if (img[row + 3]! > 24) return true; // alpha
        row += 8;
      }
    }
    return false;
  };

  const goodFallbacks: number[] = [];
  for (let i = 0; i < n; i++) if (cellInked(i)) goodFallbacks.push(i);
  // Prefer a digit as the fallback if available, else the first inked glyph.
  const fallbackIndex = goodFallbacks.length > 0 ? goodFallbacks[Math.floor(goodFallbacks.length / 2)]! : -1;

  if (fallbackIndex >= 0) {
    for (let i = 0; i < n; i++) {
      if (!cellInked(i)) {
        const [cx, cy] = cellCenter(i);
        ctx.clearRect(cx - cellPx / 2, cy - cellPx / 2, cellPx, cellPx);
        drawGlyph(chars[fallbackIndex]!, i);
      }
    }
  }

  // The glyph shader samples a single coverage channel, so upload just that as an R8 texture
  // instead of RGBA8 — a quarter of the VRAM and a quarter of the per-pixel sample bandwidth on
  // the full-resolution glyph pass, with identical sampled values. The coverage lives in the
  // canvas alpha channel; read it back AFTER any tofu fallbacks were drawn.
  const finalAlpha = ctx.getImageData(0, 0, texW, texH).data;
  const coverage = new Uint8Array(texW * texH);
  for (let i = 0; i < coverage.length; i++) coverage[i] = finalAlpha[i * 4 + 3]!;

  const texture = gl.createTexture();
  if (!texture) throw new Error("Failed to create atlas texture");
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1); // single-byte rows
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, texW, texH, 0, gl.RED, gl.UNSIGNED_BYTE, coverage);
  gl.generateMipmap(gl.TEXTURE_2D); // WebGL2 supports mipmaps on NPOT textures
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  return { texture, atlasCols, atlasRows, cellPx, glyphCount: n };
}

function isDigit(ch: string): boolean {
  return ch.length === 1 && ch >= "0" && ch <= "9";
}

export function atlasDisplayCharForGlyphMode(
  ch: string,
  index: number,
  rainGlyphCount: number,
  digitMode?: "binary" | "digits",
  digitStart = DEFAULT_DIGIT_START,
): string {
  if (index < 0 || index >= rainGlyphCount) return ch;
  const offset = index - digitStart;
  if (digitMode === "binary") return String(((offset % 2) + 2) % 2);
  if (digitMode === "digits") return String(((offset % 10) + 10) % 10);
  return ch;
}

function drawReadableDigit(ctx: CanvasRenderingContext2D, ch: string, cellPx: number): void {
  const digit = ch.charCodeAt(0) - 48;
  const segments = DIGIT_SEGMENTS[digit];
  if (!segments) return;

  const margin = cellPx * 0.2;
  const thickness = Math.max(3, cellPx * 0.12);
  const half = cellPx / 2;
  const left = -half + margin;
  const right = half - margin;
  const top = -half + margin;
  const bottom = half - margin;
  const middle = 0;
  const capInset = thickness * 0.5;

  const hSegment = (y: number): void =>
    ctx.fillRect(left + capInset, y - thickness / 2, right - left - capInset * 2, thickness);
  const vSegment = (x: number, y0: number, y1: number): void =>
    ctx.fillRect(x - thickness / 2, y0 + capInset, thickness, y1 - y0 - capInset * 2);

  if (digit === 0) {
    ctx.save();
    ctx.strokeStyle = "#ffffff";
    ctx.lineWidth = thickness;
    ctx.beginPath();
    ctx.ellipse(0, 0, half - margin - thickness / 2, half - margin - thickness / 2, 0, 0, Math.PI * 2);
    ctx.stroke();
    ctx.restore();
    return;
  }

  if (digit === 1) {
    const centerX = 0;
    ctx.fillRect(centerX - thickness / 2, top, thickness, bottom - top);
    ctx.fillRect(centerX - thickness * 1.2, top, thickness * 1.7, thickness);
    ctx.fillRect(centerX - thickness * 1.4, bottom - thickness, thickness * 2.8, thickness);
    return;
  }

  if (segments[0]) hSegment(top);
  if (segments[1]) vSegment(right, top, middle);
  if (segments[2]) vSegment(right, middle, bottom);
  if (segments[3]) hSegment(bottom);
  if (segments[4]) vSegment(left, middle, bottom);
  if (segments[5]) vSegment(left, top, middle);
  if (segments[6]) hSegment(middle);
}

const DIGIT_SEGMENTS: readonly (readonly boolean[])[] = [
  [true, true, true, true, true, true, false],
  [false, true, true, false, false, false, false],
  [true, true, false, true, true, false, true],
  [true, true, true, true, false, false, true],
  [false, true, true, false, false, true, true],
  [true, false, true, true, false, true, true],
  [true, false, true, true, true, true, true],
  [true, true, true, false, false, false, false],
  [true, true, true, true, true, true, true],
  [true, true, true, true, false, true, true],
];
