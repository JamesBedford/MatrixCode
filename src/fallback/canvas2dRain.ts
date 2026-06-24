import { createRng } from "../util/rng.ts";
import { getPreset } from "../config/colorPresets.ts";
import type { PresetName } from "../types.ts";

// Classic Canvas2D digital rain used only when WebGL2 is unavailable. Lower
// fidelity (no real bloom) but still authentic: mirrored half-width katakana,
// white leading glyph, translucent-black trail fade, per-column speeds.

export interface Canvas2dRainHandle {
  stop: () => void;
}

function rgb(c: readonly [number, number, number], a = 1): string {
  return `rgba(${Math.round(c[0] * 255)},${Math.round(c[1] * 255)},${Math.round(c[2] * 255)},${a})`;
}

export function startCanvas2dRain(
  canvas: HTMLCanvasElement,
  preset: PresetName = "classic",
  glyphScale = 1,
): Canvas2dRainHandle {
  const ctx0 = canvas.getContext("2d");
  if (!ctx0) return { stop: () => {} };
  const ctx = ctx0; // non-null, captured by the animation closures

  const colors = getPreset(preset);
  const chars: string[] = [];
  for (let cp = 0xff66; cp <= 0xff9d; cp++) chars.push(String.fromCodePoint(cp));
  for (const d of "0123456789") chars.push(d);

  const rng = createRng(7);
  const fontSize = 18 * glyphScale;
  let cols = 0;
  let drops: number[] = [];
  let speeds: number[] = [];
  let running = true;
  let raf = 0;

  function layout(): void {
    cols = Math.max(1, Math.floor(canvas.width / fontSize));
    drops = new Array(cols);
    speeds = new Array(cols);
    for (let i = 0; i < cols; i++) {
      drops[i] = Math.floor(rng() * -50);
      speeds[i] = 0.4 + rng() * 0.9;
    }
  }
  layout();
  let lastW = canvas.width;
  let lastH = canvas.height;

  const bg = rgb(colors.background, 1);
  const fade = rgb(colors.background, 0.08);

  function frame(): void {
    if (!running) return;
    if (canvas.width !== lastW || canvas.height !== lastH) {
      lastW = canvas.width;
      lastH = canvas.height;
      layout();
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, canvas.width, canvas.height);
    }

    // Translucent fade leaves decaying trails.
    ctx.fillStyle = fade;
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    ctx.font = `${fontSize}px monospace`;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    const rows = canvas.height / fontSize;

    for (let i = 0; i < cols; i++) {
      const y = drops[i]!;
      if (y >= 0) {
        const px = i * fontSize + fontSize / 2;
        const py = y * fontSize + fontSize / 2;
        const ch = chars[Math.floor(rng() * chars.length)]!;
        ctx.save();
        ctx.translate(px, py);
        ctx.scale(-1, 1); // mirror, as in the film
        ctx.fillStyle = rgb(colors.head, 1);
        ctx.shadowColor = rgb(colors.bright, 1);
        ctx.shadowBlur = 8;
        ctx.fillText(ch, 0, 0);
        ctx.restore();
      }
      drops[i]! += speeds[i]!;
      if (y * fontSize > canvas.height && rng() > 0.975) drops[i] = Math.floor(rng() * -20);
      if (y > rows + 40) drops[i] = Math.floor(rng() * -20);
    }
    raf = requestAnimationFrame(frame);
  }

  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  raf = requestAnimationFrame(frame);

  return {
    stop: () => {
      running = false;
      cancelAnimationFrame(raf);
    },
  };
}
