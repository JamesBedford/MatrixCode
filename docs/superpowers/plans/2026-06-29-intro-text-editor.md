# Intro Text Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-site **✎ Edit intro** button (next to **▷ Replay intro**) that opens a centered modal for editing the typed-intro lines, their per-line show/pause timings, and global typing settings, persisted across reloads.

**Architecture:** Move the intro to a per-line timing model in `messageOverlay.ts` (pure, unit-tested), add a localStorage-backed `IntroStore` (pure sanitize, unit-tested), build a vanilla-DOM `IntroEditor` modal mirroring `ControlsPanel`, and wire preview/save through `app.ts`. The overlay stays name-agnostic; `{name}` is substituted at play time.

**Tech Stack:** TypeScript, Vite (`vite-plugin-singlefile`), Vitest (Node env, no DOM), vanilla DOM, WebGL2 rain (untouched here).

## Global Constraints

- No new dependencies — vanilla DOM only, matching `src/ui/controlsPanel.ts`.
- Tests run in a Node environment with no DOM; only pure logic is unit-tested. DOM/UI classes are verified by typecheck + manual smoke (this matches the existing codebase — `controlsPanel.ts` has no tests).
- All UI reuses the Matrix theme CSS variables (`--mx-accent-rgb`, `--mx-dim-rgb`, `--mx-panel`, `--mx-border`, `--mx-label`, `--mx-font`) so it recolours with the active preset.
- The default intro must look **exactly as it does today**: default per-line `pauseMs` is `0` (lines run back-to-back).
- Durations are shown in the modal in **seconds** (step 0.1) and stored/handled as **milliseconds**. Typing speed is shown directly in ms/char.
- localStorage key for the script is `mx-intro`. The existing `mx-intro-seen` first-visit flag is set only by first-visit autoplay — never by Replay or Preview.
- After changes: typecheck clean (`npx tsc --noEmit`) and `npm test` green.

---

### Task 1: Per-line timing model + rewritten timeline

**Files:**
- Modify: `src/sim/messageOverlay.ts`
- Test: `test/messageOverlay.test.ts`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `interface MessageLine { text: string; holdMs: number; pauseMs: number }`
  - `interface TypeConfig { charMs: number; startDelayMs: number; fadeOutMs: number; blinkMs: number }` (no `holdMs`)
  - `const DEFAULT_HOLD_MS: number`, `const DEFAULT_PAUSE_MS: number`
  - `const DEFAULT_LINES: MessageLine[]` (with `{name}` tokens)
  - `const NAME_TOKEN: string`
  - `function resolveLines(lines: MessageLine[], name: string): MessageLine[]`
  - `function buildScript(name?: string): MessageLine[]`
  - `const DEFAULT_SCRIPT: MessageLine[]`, `const DEFAULT_TYPE_CONFIG: TypeConfig`
  - `function computeTimeline(lines, cfg, elapsedMs): TimelineState`, `function totalDuration(lines, cfg): number`
  - `MessageOverlay.setScript(lines: MessageLine[], cfg: TypeConfig): void`

- [ ] **Step 1: Rewrite the test file for the per-line model**

Replace the contents of `test/messageOverlay.test.ts` with:

```ts
import { describe, it, expect } from "vitest";
import {
  computeTimeline,
  cursorVisible,
  totalDuration,
  resolveLines,
  buildScript,
  DEFAULT_SCRIPT,
  DEFAULT_TYPE_CONFIG,
  DEFAULT_LINES,
  DEFAULT_USER_NAME,
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

describe("resolveLines", () => {
  it("substitutes every {name} token", () => {
    const out = resolveLines([{ text: "Hi {name}, {name}!", holdMs: 0, pauseMs: 0 }], "Trinity");
    expect(out[0]!.text).toBe("Hi Trinity, Trinity!");
  });

  it("falls back to the default name for blank input", () => {
    const out = resolveLines([{ text: "{name}", holdMs: 0, pauseMs: 0 }], "   ");
    expect(out[0]!.text).toBe(DEFAULT_USER_NAME);
  });

  it("default lines carry a {name} token and buildScript resolves it", () => {
    expect(DEFAULT_LINES.some((l) => l.text.includes("{name}"))).toBe(true);
    expect(buildScript("Neo").some((l) => l.text.includes("Neo"))).toBe(true);
    expect(buildScript("Neo").every((l) => !l.text.includes("{name}"))).toBe(true);
  });
});

describe("cursor", () => {
  it("blinks on a fixed period", () => {
    expect(cursorVisible(CFG, 0)).toBe(true);
    expect(cursorVisible(CFG, CFG.blinkMs)).toBe(false);
    expect(cursorVisible(CFG, CFG.blinkMs * 2)).toBe(true);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/messageOverlay.test.ts`
Expected: FAIL — type errors / missing exports (`resolveLines`, `DEFAULT_LINES`, `MessageLine.holdMs`, etc.) and the new pause/per-hold assertions don't pass against the old code.

- [ ] **Step 3: Rewrite the model in `src/sim/messageOverlay.ts`**

Replace the top of the file (the `MessageLine`/`TypeConfig` interfaces through `totalDuration`) so it reads exactly as follows. Leave `TimelineState`, `MessageOverlayOptions`, and the `MessageOverlay` class below it in place except for the edits in Steps 4–5.

```ts
export interface MessageLine {
  text: string;
  /** Milliseconds to hold the fully-typed line before clearing. */
  holdMs: number;
  /** Blank gap (cursor only) before the next line types; ignored on the last line. */
  pauseMs: number;
}

export interface TypeConfig {
  /** Milliseconds per typed character. */
  charMs: number;
  /** Blank lead-in before the first line. */
  startDelayMs: number;
  /** Fade-out duration after the final line's hold. */
  fadeOutMs: number;
  /** Cursor blink period. */
  blinkMs: number;
}

export interface TimelineState {
  /** Index of the line currently shown; equals lines.length when finished. */
  lineIndex: number;
  /** The currently-visible (possibly partial) text. */
  visibleText: string;
  /** Overall opacity 0..1. */
  opacity: number;
  /** Whether the whole sequence has completed. */
  done: boolean;
}

/** Name used when the user's own name can't be determined. */
export const DEFAULT_USER_NAME = "Neo";

/** Token in line text that is replaced with the resolved viewer name at play time. */
export const NAME_TOKEN = "{name}";

/** Default per-line timings. pauseMs is 0 so the default intro's lines run back-to-back. */
export const DEFAULT_HOLD_MS = 2800;
export const DEFAULT_PAUSE_MS = 0;

/** Default intro lines, carrying {name} tokens for runtime substitution. */
export const DEFAULT_LINES: MessageLine[] = [
  { text: `Wake up, ${NAME_TOKEN}...`, holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: "The Matrix has you...", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: "Follow the white rabbit.", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
  { text: `Knock, knock, ${NAME_TOKEN}.`, holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS },
];

/** Substitute the {name} token in every line with the given name (blank → default). */
export function resolveLines(lines: MessageLine[], name: string = DEFAULT_USER_NAME): MessageLine[] {
  const who = name.trim() || DEFAULT_USER_NAME;
  return lines.map((l) => ({ ...l, text: l.text.split(NAME_TOKEN).join(who) }));
}

/** Build the default typed intro script, addressing the viewer by name. */
export function buildScript(name: string = DEFAULT_USER_NAME): MessageLine[] {
  return resolveLines(DEFAULT_LINES, name);
}

/**
 * Resolve the viewer's name from the runtime environment, falling back to
 * DEFAULT_USER_NAME ("Neo") when it can't be determined. Sources, in order:
 *   1. `?name=` URL query parameter
 *   2. `mx-user-name` in localStorage
 */
export function resolveUserName(): string {
  try {
    const fromQuery = new URLSearchParams(window.location.search).get("name");
    if (fromQuery && fromQuery.trim()) return fromQuery.trim();

    const fromStore = window.localStorage.getItem("mx-user-name");
    if (fromStore && fromStore.trim()) return fromStore.trim();
  } catch {
    // Non-browser environment or storage blocked — fall through to default.
  }
  return DEFAULT_USER_NAME;
}

export const DEFAULT_SCRIPT: MessageLine[] = buildScript();

export const DEFAULT_TYPE_CONFIG: TypeConfig = {
  charMs: 95,
  startDelayMs: 600,
  fadeOutMs: 900,
  blinkMs: 450,
};

/** Pure: given elapsed ms since start, compute what to show. */
export function computeTimeline(lines: MessageLine[], cfg: TypeConfig, elapsedMs: number): TimelineState {
  if (lines.length === 0) return { lineIndex: 0, visibleText: "", opacity: 0, done: true };

  let t = elapsedMs - cfg.startDelayMs;
  if (t < 0) return { lineIndex: 0, visibleText: "", opacity: 1, done: false };

  const lastIdx = lines.length - 1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const typeDur = line.text.length * cfg.charMs;
    if (t < typeDur) {
      const chars = Math.floor(t / cfg.charMs);
      return { lineIndex: i, visibleText: line.text.slice(0, chars), opacity: 1, done: false };
    }
    t -= typeDur;
    if (t < line.holdMs) {
      return { lineIndex: i, visibleText: line.text, opacity: 1, done: false };
    }
    t -= line.holdMs;
    // Blank pause before the next line (none after the last line).
    if (i < lastIdx) {
      if (t < line.pauseMs) {
        return { lineIndex: i, visibleText: "", opacity: 1, done: false };
      }
      t -= line.pauseMs;
    }
  }

  const lastText = lines[lastIdx]!.text;
  if (t < cfg.fadeOutMs) {
    return { lineIndex: lastIdx, visibleText: lastText, opacity: 1 - t / cfg.fadeOutMs, done: false };
  }
  return { lineIndex: lines.length, visibleText: "", opacity: 0, done: true };
}

/** Pure: cursor visible at this elapsed time (blink). */
export function cursorVisible(cfg: TypeConfig, elapsedMs: number): boolean {
  return Math.floor(elapsedMs / cfg.blinkMs) % 2 === 0;
}

/** Total runtime of the sequence in ms (useful for tests / scheduling). */
export function totalDuration(lines: MessageLine[], cfg: TypeConfig): number {
  let total = cfg.startDelayMs + cfg.fadeOutMs;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    total += line.text.length * cfg.charMs + line.holdMs;
    if (i < lines.length - 1) total += line.pauseMs;
  }
  return total;
}
```

- [ ] **Step 4: Add `setScript` to the `MessageOverlay` class**

In the `MessageOverlay` class (further down the same file), add this method immediately after the `onDone` method:

```ts
  /** Replace the script and timing config (used by the live intro editor). */
  setScript(lines: MessageLine[], cfg: TypeConfig): void {
    this.lines = lines;
    this.cfg = cfg;
  }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx vitest run test/messageOverlay.test.ts`
Expected: PASS (all describe blocks green).

- [ ] **Step 6: Typecheck**

Run: `npx tsc --noEmit`
Expected: no errors. (`app.ts` still compiles because `buildScript`/`DEFAULT_SCRIPT` remain exported with the new `MessageLine` shape.)

- [ ] **Step 7: Commit**

```bash
git add src/sim/messageOverlay.ts test/messageOverlay.test.ts
git commit -m "Move intro to per-line hold/pause timing model with {name} tokens"
```

---

### Task 2: IntroStore (persistence + sanitize)

**Files:**
- Create: `src/config/introStore.ts`
- Test: `test/introStore.test.ts`

**Interfaces:**
- Consumes: `MessageLine`, `TypeConfig`, `DEFAULT_LINES`, `DEFAULT_TYPE_CONFIG`, `DEFAULT_HOLD_MS`, `DEFAULT_PAUSE_MS` from `src/sim/messageOverlay.ts`; `clamp` from `src/util/math.ts`.
- Produces:
  - `interface IntroScript { lines: MessageLine[]; charMs: number; startDelayMs: number; fadeOutMs: number }`
  - `const DEFAULT_INTRO: IntroScript`
  - `function cloneIntro(s: IntroScript): IntroScript`
  - `function sanitizeIntro(raw: unknown): IntroScript`
  - `function toTypeConfig(s: IntroScript): TypeConfig`
  - `class IntroStore { get(): IntroScript; set(s: IntroScript): void; reset(): IntroScript }`

- [ ] **Step 1: Write the failing test**

Create `test/introStore.test.ts`:

```ts
import { beforeEach, describe, it, expect } from "vitest";
import {
  IntroStore,
  sanitizeIntro,
  cloneIntro,
  toTypeConfig,
  DEFAULT_INTRO,
} from "../src/config/introStore.ts";
import { DEFAULT_TYPE_CONFIG } from "../src/sim/messageOverlay.ts";

class MemoryStorage {
  private m = new Map<string, string>();
  getItem(k: string): string | null {
    return this.m.has(k) ? this.m.get(k)! : null;
  }
  setItem(k: string, v: string): void {
    this.m.set(k, v);
  }
  removeItem(k: string): void {
    this.m.delete(k);
  }
}

beforeEach(() => {
  (globalThis as unknown as { localStorage: MemoryStorage }).localStorage = new MemoryStorage();
});

describe("sanitizeIntro", () => {
  it("clamps out-of-range numbers", () => {
    const s = sanitizeIntro({ lines: [{ text: "x", holdMs: 999999, pauseMs: -50 }], charMs: 9999, startDelayMs: -10, fadeOutMs: 999999 });
    expect(s.lines[0]!.holdMs).toBe(20000);
    expect(s.lines[0]!.pauseMs).toBe(0);
    expect(s.charMs).toBe(500);
    expect(s.startDelayMs).toBe(0);
    expect(s.fadeOutMs).toBe(10000);
  });

  it("caps the number of lines and the text length", () => {
    const many = Array.from({ length: 30 }, () => ({ text: "a".repeat(300), holdMs: 100, pauseMs: 0 }));
    const s = sanitizeIntro({ lines: many });
    expect(s.lines.length).toBe(12);
    expect(s.lines[0]!.text.length).toBe(120);
  });

  it("drops malformed lines and uses fallbacks for missing fields", () => {
    const s = sanitizeIntro({ lines: [null, 5, { text: "ok" }, "nope"] });
    expect(s.lines.length).toBe(1);
    expect(s.lines[0]!.text).toBe("ok");
    expect(s.lines[0]!.holdMs).toBe(DEFAULT_INTRO.lines[0]!.holdMs);
    expect(s.lines[0]!.pauseMs).toBe(0);
  });

  it("falls back to default lines when none are valid or the array is empty", () => {
    expect(sanitizeIntro({ lines: [] }).lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(sanitizeIntro({}).lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(sanitizeIntro("garbage").charMs).toBe(DEFAULT_INTRO.charMs);
  });
});

describe("toTypeConfig", () => {
  it("builds a TypeConfig including the default blink period", () => {
    const cfg = toTypeConfig({ lines: [], charMs: 80, startDelayMs: 100, fadeOutMs: 200 });
    expect(cfg.charMs).toBe(80);
    expect(cfg.startDelayMs).toBe(100);
    expect(cfg.fadeOutMs).toBe(200);
    expect(cfg.blinkMs).toBe(DEFAULT_TYPE_CONFIG.blinkMs);
  });
});

describe("cloneIntro", () => {
  it("deep-copies lines so mutations don't leak", () => {
    const a = cloneIntro(DEFAULT_INTRO);
    a.lines[0]!.text = "changed";
    expect(DEFAULT_INTRO.lines[0]!.text).not.toBe("changed");
  });
});

describe("IntroStore", () => {
  it("returns defaults with no stored value", () => {
    expect(new IntroStore().get().lines.length).toBe(DEFAULT_INTRO.lines.length);
  });

  it("persists across instances (round-trip)", () => {
    const a = new IntroStore();
    a.set({ lines: [{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }], charMs: 50, startDelayMs: 0, fadeOutMs: 0 });
    const b = new IntroStore();
    expect(b.get().lines).toEqual([{ text: "hi {name}", holdMs: 1000, pauseMs: 500 }]);
    expect(b.get().charMs).toBe(50);
  });

  it("reset clears storage and returns defaults", () => {
    const s = new IntroStore();
    s.set({ lines: [{ text: "x", holdMs: 1, pauseMs: 1 }], charMs: 50, startDelayMs: 1, fadeOutMs: 1 });
    const after = s.reset();
    expect(after.lines.length).toBe(DEFAULT_INTRO.lines.length);
    expect(new IntroStore().get().lines.length).toBe(DEFAULT_INTRO.lines.length);
  });

  it("falls back to defaults on malformed stored JSON", () => {
    localStorage.setItem("mx-intro", "{not json");
    expect(new IntroStore().get().charMs).toBe(DEFAULT_INTRO.charMs);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `npx vitest run test/introStore.test.ts`
Expected: FAIL — `Cannot find module '../src/config/introStore.ts'`.

- [ ] **Step 3: Write the implementation**

Create `src/config/introStore.ts`:

```ts
import type { MessageLine, TypeConfig } from "../sim/messageOverlay.ts";
import {
  DEFAULT_LINES,
  DEFAULT_TYPE_CONFIG,
  DEFAULT_HOLD_MS,
  DEFAULT_PAUSE_MS,
} from "../sim/messageOverlay.ts";
import { clamp } from "../util/math.ts";

/** User-editable intro: the lines plus the global timing settings (blink stays default). */
export interface IntroScript {
  lines: MessageLine[];
  charMs: number;
  startDelayMs: number;
  fadeOutMs: number;
}

const STORAGE_KEY = "mx-intro";
const MAX_LINES = 12;
const MAX_TEXT_LEN = 120;

export const DEFAULT_INTRO: IntroScript = {
  lines: DEFAULT_LINES.map((l) => ({ ...l })),
  charMs: DEFAULT_TYPE_CONFIG.charMs,
  startDelayMs: DEFAULT_TYPE_CONFIG.startDelayMs,
  fadeOutMs: DEFAULT_TYPE_CONFIG.fadeOutMs,
};

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneIntro(s: IntroScript): IntroScript {
  return { ...s, lines: s.lines.map((l) => ({ ...l })) };
}

function num(v: unknown, min: number, max: number, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? clamp(v, min, max) : fallback;
}

function sanitizeLine(raw: unknown): MessageLine | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.text !== "string") return null;
  return {
    text: r.text.slice(0, MAX_TEXT_LEN),
    holdMs: num(r.holdMs, 0, 20000, DEFAULT_HOLD_MS),
    pauseMs: num(r.pauseMs, 0, 20000, DEFAULT_PAUSE_MS),
  };
}

/** Coerce arbitrary parsed JSON into a valid IntroScript, falling back to defaults. */
export function sanitizeIntro(raw: unknown): IntroScript {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const rawLines = Array.isArray(r.lines) ? r.lines : [];
  const lines = rawLines
    .slice(0, MAX_LINES)
    .map(sanitizeLine)
    .filter((l): l is MessageLine => l !== null);
  return {
    lines: lines.length > 0 ? lines : DEFAULT_INTRO.lines.map((l) => ({ ...l })),
    charMs: num(r.charMs, 10, 500, DEFAULT_INTRO.charMs),
    startDelayMs: num(r.startDelayMs, 0, 10000, DEFAULT_INTRO.startDelayMs),
    fadeOutMs: num(r.fadeOutMs, 0, 10000, DEFAULT_INTRO.fadeOutMs),
  };
}

/** Build the overlay's TypeConfig from a stored script (blink period is not user-facing). */
export function toTypeConfig(s: IntroScript): TypeConfig {
  return {
    charMs: s.charMs,
    startDelayMs: s.startDelayMs,
    fadeOutMs: s.fadeOutMs,
    blinkMs: DEFAULT_TYPE_CONFIG.blinkMs,
  };
}

/** localStorage-backed store for the user's custom intro script. */
export class IntroStore {
  private script: IntroScript;

  constructor() {
    this.script = this.load();
  }

  private load(): IntroScript {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return cloneIntro(DEFAULT_INTRO);
      return sanitizeIntro(JSON.parse(raw) as unknown);
    } catch {
      return cloneIntro(DEFAULT_INTRO);
    }
  }

  get(): IntroScript {
    return cloneIntro(this.script);
  }

  set(script: IntroScript): void {
    this.script = sanitizeIntro(script);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.script));
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }

  reset(): IntroScript {
    this.script = cloneIntro(DEFAULT_INTRO);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      /* ignore */
    }
    return this.get();
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npx vitest run test/introStore.test.ts`
Expected: PASS.

- [ ] **Step 5: Typecheck and run the full suite**

Run: `npx tsc --noEmit && npm test`
Expected: no type errors; all tests green.

- [ ] **Step 6: Commit**

```bash
git add src/config/introStore.ts test/introStore.test.ts
git commit -m "Add IntroStore: localStorage persistence + sanitize for custom intro"
```

---

### Task 3: Intro editor modal (DOM) + styles

**Files:**
- Create: `src/ui/introEditor.ts`
- Modify: `src/styles.css`

**Interfaces:**
- Consumes: `IntroScript`, `IntroStore`, `DEFAULT_INTRO`, `cloneIntro` from `src/config/introStore.ts`; `DEFAULT_HOLD_MS`, `DEFAULT_PAUSE_MS` from `src/sim/messageOverlay.ts`.
- Produces:
  - `interface IntroEditorCallbacks { onPreview(draft: IntroScript): void; onSave(draft: IntroScript): void; onCancel(): void }`
  - `class IntroEditor { constructor(parent: HTMLElement, store: IntroStore, cb: IntroEditorCallbacks); open(): void; endPreview(): void; destroy(): void }`

Note: this is a vanilla-DOM UI class with no Node-testable pure logic, so (like `controlsPanel.ts`) it has no unit test. It is verified by typecheck and a manual smoke test.

- [ ] **Step 1: Create the editor class**

Create `src/ui/introEditor.ts`:

```ts
import { type IntroScript, IntroStore, DEFAULT_INTRO, cloneIntro } from "../config/introStore.ts";
import { DEFAULT_HOLD_MS, DEFAULT_PAUSE_MS } from "../sim/messageOverlay.ts";

export interface IntroEditorCallbacks {
  /** Play the draft over the rain (the editor hides itself first). */
  onPreview: (draft: IntroScript) => void;
  /** Persist the draft and update the live overlay. */
  onSave: (draft: IntroScript) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

/** Centered modal for editing the typed-intro script. Mirrors ControlsPanel's vanilla-DOM style. */
export class IntroEditor {
  readonly el: HTMLDivElement; // backdrop
  private dialog: HTMLDivElement;
  private linesEl: HTMLDivElement;
  private draft: IntroScript;
  private isOpen = false;
  private previewing = false;

  constructor(parent: HTMLElement, private store: IntroStore, private cb: IntroEditorCallbacks) {
    this.draft = cloneIntro(DEFAULT_INTRO);

    this.el = document.createElement("div");
    this.el.className = "mx-modal-backdrop";
    this.el.style.display = "none";
    this.el.addEventListener("click", (e) => {
      if (e.target === this.el) this.cancel();
    });

    this.dialog = document.createElement("div");
    this.dialog.className = "mx-modal";
    this.dialog.setAttribute("role", "dialog");
    this.dialog.setAttribute("aria-modal", "true");
    this.dialog.setAttribute("aria-label", "Edit intro");
    this.el.appendChild(this.dialog);

    this.linesEl = document.createElement("div");

    parent.appendChild(this.el);
    // Capture phase so this runs before app.ts's window keydown handler; while the
    // editor is open we swallow shortcuts (incl. f/h) and handle Escape ourselves.
    window.addEventListener("keydown", this.onKeyDownCapture, true);
  }

  private onKeyDownCapture = (e: KeyboardEvent): void => {
    if (!this.isOpen || this.previewing) return;
    e.stopPropagation();
    if (e.key === "Escape") {
      e.preventDefault();
      this.cancel();
    }
  };

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.el.style.display = "grid";
    this.isOpen = true;
    this.previewing = false;
  }

  private hide(): void {
    this.el.style.display = "none";
    this.isOpen = false;
  }

  /** Called by the app when a preview ends (finished or skipped) to restore the editor. */
  endPreview(): void {
    if (!this.previewing) return;
    this.previewing = false;
    this.el.style.display = "grid";
  }

  private cancel(): void {
    this.hide();
    this.cb.onCancel();
  }

  private save(): void {
    this.hide();
    this.cb.onSave(cloneIntro(this.draft));
  }

  private preview(): void {
    this.previewing = true;
    this.el.style.display = "none"; // unobstruct the centered intro; restored via endPreview()
    this.cb.onPreview(cloneIntro(this.draft));
  }

  private build(): void {
    this.dialog.replaceChildren();

    this.dialog.appendChild(this.heading("h2", "Edit intro"));
    this.dialog.appendChild(this.heading("h3", "Lines"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Use {name} to insert the visitor’s name.";
    this.dialog.appendChild(hint);

    this.linesEl = document.createElement("div");
    this.dialog.appendChild(this.linesEl);
    this.renderLines();

    const add = this.textButton("+ Add line", "mx-btn mx-modal-add", () => {
      this.draft.lines.push({ text: "", holdMs: DEFAULT_HOLD_MS, pauseMs: DEFAULT_PAUSE_MS });
      this.renderLines();
    });
    this.dialog.appendChild(add);

    this.dialog.appendChild(this.heading("h3", "Timing"));
    const timing = document.createElement("div");
    timing.className = "mx-line-timings";
    timing.appendChild(this.numberField("Typing speed (ms/char)", this.draft.charMs, 10, 500, 5, (v) => (this.draft.charMs = v)));
    timing.appendChild(this.secondsField("Start delay (s)", this.draft.startDelayMs, (ms) => (this.draft.startDelayMs = ms)));
    timing.appendChild(this.secondsField("Fade out (s)", this.draft.fadeOutMs, (ms) => (this.draft.fadeOutMs = ms)));
    this.dialog.appendChild(timing);

    const footer = document.createElement("div");
    footer.className = "mx-modal-footer";
    footer.appendChild(this.textButton("Reset to default", "mx-btn mx-reset", () => {
      this.draft = cloneIntro(DEFAULT_INTRO);
      this.build();
    }));
    footer.appendChild(this.textButton("Cancel", "mx-btn", () => this.cancel()));
    footer.appendChild(this.textButton("Preview", "mx-btn", () => this.preview()));
    footer.appendChild(this.textButton("Save", "mx-btn", () => this.save()));
    this.dialog.appendChild(footer);
  }

  private renderLines(): void {
    this.linesEl.replaceChildren();
    const lines = this.draft.lines;
    lines.forEach((line, i) => {
      const row = document.createElement("div");
      row.className = "mx-line";

      const reorder = document.createElement("div");
      reorder.className = "mx-line-reorder";
      const up = this.iconButton("↑", "Move line up", () => this.move(i, -1));
      up.disabled = i === 0;
      const down = this.iconButton("↓", "Move line down", () => this.move(i, 1));
      down.disabled = i === lines.length - 1;
      reorder.append(up, down);
      row.appendChild(reorder);

      const text = document.createElement("input");
      text.type = "text";
      text.value = line.text;
      text.placeholder = "(blank line)";
      text.addEventListener("input", () => (line.text = text.value));
      row.appendChild(text);

      const timings = document.createElement("div");
      timings.className = "mx-line-timings";
      timings.appendChild(this.secondsField("Show for (s)", line.holdMs, (ms) => (line.holdMs = ms)));
      const pause = this.secondsField("Pause after (s)", line.pauseMs, (ms) => (line.pauseMs = ms));
      if (i === lines.length - 1) {
        const input = pause.querySelector("input");
        if (input) input.disabled = true; // last line has no following line to pause before
      }
      timings.appendChild(pause);
      const remove = this.iconButton("✕", "Remove line", () => {
        this.draft.lines.splice(i, 1);
        this.renderLines();
      });
      remove.disabled = lines.length === 1; // always keep at least one line
      timings.appendChild(remove);
      row.appendChild(timings);

      this.linesEl.appendChild(row);
    });
  }

  private move(i: number, dir: number): void {
    const j = i + dir;
    const lines = this.draft.lines;
    if (j < 0 || j >= lines.length) return;
    [lines[i], lines[j]] = [lines[j]!, lines[i]!];
    this.renderLines();
  }

  private heading(tag: "h2" | "h3", text: string): HTMLElement {
    const h = document.createElement(tag);
    h.textContent = text;
    return h;
  }

  private numberField(
    label: string,
    value: number,
    min: number,
    max: number,
    step: number,
    onChange: (v: number) => void,
  ): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field";
    const span = document.createElement("span");
    span.textContent = label;
    const input = document.createElement("input");
    input.type = "number";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    input.value = String(value);
    input.addEventListener("input", () => {
      const v = Number(input.value);
      if (Number.isFinite(v)) onChange(v);
    });
    field.append(span, input);
    return field;
  }

  private secondsField(label: string, valueMs: number, onChangeMs: (ms: number) => void): HTMLElement {
    return this.numberField(label, valueMs / 1000, 0, 60, 0.1, (s) => onChangeMs(Math.round(s * 1000)));
  }

  private iconButton(label: string, title: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "mx-icon-btn";
    b.title = title;
    b.setAttribute("aria-label", title);
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  private textButton(label: string, className: string, onClick: () => void): HTMLButtonElement {
    const b = document.createElement("button");
    b.type = "button";
    b.className = className;
    b.textContent = label;
    b.addEventListener("click", onClick);
    return b;
  }

  destroy(): void {
    window.removeEventListener("keydown", this.onKeyDownCapture, true);
    this.el.remove();
  }
}
```

- [ ] **Step 2: Add the modal styles**

Append to the end of `src/styles.css`:

```css
/* ---------- Intro editor modal ---------- */
.mx-modal-backdrop {
  position: fixed;
  inset: 0;
  z-index: 30;
  display: grid;
  place-items: center;
  padding: 24px;
  background: rgba(0, 0, 0, 0.6);
  backdrop-filter: blur(3px);
}
.mx-modal {
  width: min(560px, 100%);
  max-height: calc(100vh - 48px);
  overflow-y: auto;
  padding: 20px 22px 18px;
  background: var(--mx-panel);
  border: 1px solid var(--mx-border);
  border-radius: 12px;
  box-shadow: 0 12px 60px rgba(0, 0, 0, 0.7), inset 0 0 28px rgb(var(--mx-accent-rgb) / 0.05);
}
.mx-modal h2 {
  margin: 0 0 4px;
  font-size: 14px;
  font-weight: 600;
  letter-spacing: 0.2em;
  text-transform: uppercase;
  color: var(--mx-green);
  text-shadow: 0 0 8px rgb(var(--mx-accent-rgb) / 0.5);
}
.mx-modal h3 {
  margin: 18px 0 8px;
  font-size: 11px;
  font-weight: 600;
  letter-spacing: 0.16em;
  text-transform: uppercase;
  color: var(--mx-label);
}
.mx-modal-hint {
  margin: 0 0 8px;
  font-size: 10px;
  letter-spacing: 0.04em;
  color: rgb(var(--mx-accent-rgb) / 0.5);
}
.mx-line {
  display: grid;
  grid-template-columns: auto 1fr;
  gap: 8px;
  align-items: center;
  padding: 8px 10px;
  margin: 8px 0;
  border: 1px solid var(--mx-border);
  border-radius: 8px;
  background: rgb(var(--mx-accent-rgb) / 0.04);
}
.mx-line-reorder {
  display: flex;
  flex-direction: column;
  gap: 3px;
}
.mx-line-timings {
  grid-column: 1 / -1;
  display: flex;
  flex-wrap: wrap;
  gap: 10px 16px;
  align-items: center;
}
.mx-field {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.mx-field > span {
  font-size: 10px;
  letter-spacing: 0.05em;
  text-transform: uppercase;
  color: var(--mx-label);
}
.mx-modal input[type="text"],
.mx-modal input[type="number"] {
  font-family: var(--mx-font);
  font-size: 12px;
  color: var(--mx-green);
  background: rgb(0 0 0 / 0.35);
  border: 1px solid var(--mx-border);
  border-radius: 5px;
  padding: 6px 8px;
}
.mx-modal input[type="text"] {
  width: 100%;
}
.mx-modal input[type="number"] {
  width: 6ch;
  text-align: right;
}
.mx-modal input:focus {
  outline: none;
  border-color: var(--mx-green);
  box-shadow: 0 0 8px rgb(var(--mx-accent-rgb) / 0.35);
}
.mx-modal input:disabled {
  opacity: 0.35;
}
.mx-icon-btn {
  appearance: none;
  cursor: pointer;
  font-family: var(--mx-font);
  font-size: 12px;
  line-height: 1;
  color: var(--mx-green);
  background: rgb(var(--mx-accent-rgb) / 0.06);
  border: 1px solid var(--mx-border);
  border-radius: 4px;
  padding: 3px 7px;
}
.mx-icon-btn:hover:not(:disabled) {
  border-color: var(--mx-green);
}
.mx-icon-btn:disabled {
  opacity: 0.3;
  cursor: default;
}
.mx-modal-add {
  margin-top: 4px;
}
.mx-modal-footer {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  justify-content: flex-end;
  margin-top: 18px;
}
.mx-modal-footer .mx-reset {
  margin-right: auto;
}
```

- [ ] **Step 3: Hide the modal in multi-monitor mode**

In `src/styles.css`, find the existing super-mode rule:

```css
#app.mx-multimonitor .mx-ui,
#app.mx-multimonitor .mx-message {
  display: none !important;
}
```

Replace it with:

```css
#app.mx-multimonitor .mx-ui,
#app.mx-multimonitor .mx-message,
#app.mx-multimonitor .mx-modal-backdrop {
  display: none !important;
}
```

- [ ] **Step 4: Typecheck**

Run: `npx tsc --noEmit`
Expected: no errors. (The class is not yet imported anywhere; that's fine — it still type-checks. It gets wired in Task 4.)

- [ ] **Step 5: Commit**

```bash
git add src/ui/introEditor.ts src/styles.css
git commit -m "Add intro editor modal UI and styles"
```

---

### Task 4: Wire the editor into the app

**Files:**
- Modify: `src/ui/controlsPanel.ts`
- Modify: `src/app.ts`

**Interfaces:**
- Consumes: `IntroEditor`, `IntroEditorCallbacks` from `src/ui/introEditor.ts`; `IntroStore`, `IntroScript`, `toTypeConfig` from `src/config/introStore.ts`; `resolveLines`, `resolveUserName`, `MessageOverlay` from `src/sim/messageOverlay.ts`.
- Produces: `PanelCallbacks` gains `onEditIntro: () => void`.

This task is integration/DOM wiring (no Node-testable logic); verified by typecheck + manual smoke test.

- [ ] **Step 1: Add the Edit-intro callback and button to the panel**

In `src/ui/controlsPanel.ts`, change the `PanelCallbacks` interface to:

```ts
export interface PanelCallbacks {
  onToggleFullscreen: () => void;
  onReplayIntro: () => void;
  onEditIntro: () => void;
}
```

Then, in the constructor, locate this block:

```ts
    const replay = this.button("▷ Replay intro", () => this.cb.onReplayIntro());
    replay.style.marginTop = "6px";
    this.panel.appendChild(replay);
```

and add the Edit-intro button immediately after it:

```ts
    const edit = this.button("✎ Edit intro", () => this.cb.onEditIntro());
    edit.style.marginTop = "6px";
    this.panel.appendChild(edit);
```

- [ ] **Step 2: Update the imports in `src/app.ts`**

Change the `messageOverlay` import line:

```ts
import { MessageOverlay, buildScript, resolveUserName } from "./sim/messageOverlay.ts";
```

to:

```ts
import { MessageOverlay, resolveLines, resolveUserName } from "./sim/messageOverlay.ts";
```

Then add these two imports next to the other `./config` / `./ui` imports:

```ts
import { IntroStore, toTypeConfig, type IntroScript } from "./config/introStore.ts";
import { IntroEditor } from "./ui/introEditor.ts";
```

- [ ] **Step 3: Replace the overlay/panel construction block**

In `src/app.ts`, find this block (the `// ---------- Overlays ----------` section):

```ts
  // ---------- Overlays ----------
  // Panels are a pure backdrop — no intro, no controls UI.
  const message = panelConfig ? null : new MessageOverlay(container, { lines: buildScript(resolveUserName()) });
  const panel = panelConfig
    ? null
    : new ControlsPanel(container, controls, {
        onToggleFullscreen: () => toggleFullscreen(),
        onReplayIntro: () => message?.play(performance.now()),
      });
```

Replace it with:

```ts
  // ---------- Overlays ----------
  // Panels are a pure backdrop — no intro, no controls UI.
  const introStore = panelConfig ? null : new IntroStore();
  const viewerName = resolveUserName();
  const message = panelConfig ? null : new MessageOverlay(container);

  // Reflect the stored script onto the live overlay (resolving {name}).
  const seedOverlay = (): void => {
    if (!message || !introStore) return;
    const s = introStore.get();
    message.setScript(resolveLines(s.lines, viewerName), toTypeConfig(s));
  };
  seedOverlay();

  // Preview/save run through the overlay; markSeenPending gates the first-visit flag.
  let introPreviewActive = false;
  let markSeenPending = false;

  const previewIntro = (draft: IntroScript): void => {
    if (!message) return;
    introPreviewActive = true;
    message.setScript(resolveLines(draft.lines, viewerName), toTypeConfig(draft));
    message.play(performance.now());
  };

  const saveIntro = (draft: IntroScript): void => {
    if (!introStore) return;
    introStore.set(draft);
    seedOverlay();
  };

  // A single onDone handler serves both the first-visit flag and preview restore.
  message?.onDone(() => {
    if (introPreviewActive) {
      introPreviewActive = false;
      editor?.endPreview();
    }
    if (markSeenPending) {
      markSeenPending = false;
      try {
        localStorage.setItem(INTRO_KEY, "1");
      } catch {
        /* ignore */
      }
    }
  });

  let editor: IntroEditor | null = null;
  if (!panelConfig && introStore && message) {
    editor = new IntroEditor(container, introStore, {
      onPreview: previewIntro,
      onSave: saveIntro,
      onCancel: () => {},
    });
  }

  const panel = panelConfig
    ? null
    : new ControlsPanel(container, controls, {
        onToggleFullscreen: () => toggleFullscreen(),
        onReplayIntro: () => message?.play(performance.now()),
        onEditIntro: () => editor?.open(),
      });
```

(`editor` is referenced inside the `onDone` closure before its declaration; that is safe because the closure only runs later at runtime, and `editor` is a `let` in the same scope. The `panel` const intentionally comes after `editor` so its `onEditIntro` can call `editor.open()`.)

- [ ] **Step 4: Update `maybePlayIntro` to use the shared onDone**

In `src/app.ts`, find the `maybePlayIntro` function:

```ts
  const maybePlayIntro = (): void => {
    if (!message || reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) return;
    message.onDone(() => {
      try {
        localStorage.setItem(INTRO_KEY, "1");
      } catch {
        /* ignore */
      }
    });
    message.play(performance.now());
  };
```

Replace it with:

```ts
  const maybePlayIntro = (): void => {
    if (!message || reduceMq.matches) return;
    let seen = false;
    try {
      seen = localStorage.getItem(INTRO_KEY) === "1";
    } catch {
      /* ignore */
    }
    if (seen) return;
    markSeenPending = true;
    message.play(performance.now());
  };
```

- [ ] **Step 5: Destroy the editor on teardown**

In `src/app.ts`, find this line in the `destroy` callback:

```ts
      panel?.destroy();
      message?.destroy();
```

Replace it with:

```ts
      editor?.destroy();
      panel?.destroy();
      message?.destroy();
```

- [ ] **Step 6: Typecheck and run the full suite**

Run: `npx tsc --noEmit && npm test`
Expected: no type errors; all tests green.

- [ ] **Step 7: Manual smoke test**

Assume the dev server (`npm run dev`, port 5188) is already running. In the browser:
1. Open the controls panel (move the mouse / press `H`). Confirm an **✎ Edit intro** button sits below **▷ Replay intro**.
2. Click **✎ Edit intro** — the modal appears centered with the four default lines, each showing the text plus "Show for"/"Pause after" fields; the last line's "Pause after" is disabled.
3. Edit a line's text, add a line, reorder with ↑/↓, delete a line (the ✕ is disabled when only one line remains). Type `{name}` in a line.
4. Click **Preview** — the modal disappears and the typed intro plays over the rain (with `{name}` replaced). Let it finish (or click/Esc to skip) — the modal reappears.
5. Click **Save** — the modal closes. Click **▷ Replay intro** — your edited intro plays.
6. Reload the page and replay — the custom intro persists.
7. Reopen the editor, click **Reset to default**, then **Save** — the original "Wake up, Neo…" intro returns.
8. While the modal is open, press `f` and `h` — confirm they do **not** toggle fullscreen/panel (shortcuts are suppressed); press `Esc` — the modal closes.
9. Change the **Color** preset and reopen the editor — confirm the modal recolours to match.

- [ ] **Step 8: Commit**

```bash
git add src/app.ts src/ui/controlsPanel.ts
git commit -m "Wire intro editor: Edit-intro button, preview, save, persistence"
```

---

## Self-Review Notes

- **Spec coverage:** edit/add/remove/reorder lines (Task 3 `renderLines`/`move`/add/remove); per-line hold + pause (Task 1 model, Task 3 fields); global typing speed/start delay/fade-out (Task 1 `TypeConfig`, Task 3 timing section); `{name}` token (Task 1 `resolveLines`, wired in Task 4); Preview + Save + Cancel + Reset (Task 3 footer, Task 4 handlers); localStorage persistence (Task 2); button next to Replay (Task 4 Step 1); Escape coordination + shortcut suppression (Task 3 capture listener); default look preserved via `pauseMs: 0` (Task 1); seconds-in-UI/ms-stored (Task 3 `secondsField`); intro-seen flag untouched by replay/preview (Task 4 `markSeenPending`); modal hidden in multi-monitor mode (Task 3 Step 3); editor teardown (Task 4 Step 5).
- **Type consistency:** `setScript(lines, cfg)`, `resolveLines(lines, name)`, `toTypeConfig(script)`, `cloneIntro(script)`, `sanitizeIntro(raw)`, `IntroScript`, `IntroEditorCallbacks` are used with identical signatures across tasks. `DEFAULT_HOLD_MS`/`DEFAULT_PAUSE_MS` are the single source of truth for per-line defaults (consumed by both `introStore.ts` and `introEditor.ts`).
- **No placeholders:** every code step contains complete, runnable code.
