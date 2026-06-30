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
}

const DEFAULT_FONT_STACK =
  '"Hiragino Kaku Gothic ProN", "Hiragino Kaku Gothic Pro", "Yu Gothic", "Meiryo", "MS Gothic", "Noto Sans JP", monospace';

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
  const drawGlyph = (ch: string, i: number): void => {
    const [cx, cy] = cellCenter(i);
    ctx.save();
    ctx.translate(cx, cy);
    if (opts.mirror && i < mirrorExcludeFrom) ctx.scale(-1, 1); // message glyphs (>= cutoff) stay readable
    ctx.fillText(ch, 0, 0);
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

  const texture = gl.createTexture();
  if (!texture) throw new Error("Failed to create atlas texture");
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, 0);
  gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, 0);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, canvas);
  gl.generateMipmap(gl.TEXTURE_2D); // WebGL2 supports mipmaps on NPOT textures
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

  return { texture, atlasCols, atlasRows, cellPx, glyphCount: n };
}
