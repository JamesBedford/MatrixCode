# Named moments ({countup} and named countdowns) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `{countup}` token and named countdown/countup moments (`{countdown:NAME}` / `{countup:NAME}`) backed by a user-managed list, discoverable via a hover in the intro and messages editors.

**Architecture:** Extend the single-target `CountdownStore` into a default target plus a list of named moments. The pure `resolveTokens` gains a `moments` lookup and a `{countup}` direction (reusing `formatCountdown`). `app.ts` builds the moments record into the existing per-frame resolver, and passes a `getMomentNames` callback to the intro/messages editors for the hover.

**Tech Stack:** TypeScript, Vite (single-file build via `vite-plugin-singlefile`), Vitest (Node env, no DOM). Vanilla-DOM UI via the `ModalEditor` kit.

## Global Constraints

- localStorage key stays `mx-countdown` (no version bump); old `{ targetMs }` blobs must load unchanged.
- Bare `{countdown}` / `{countup}` behaviour is preserved (default target = `countdownTargetMs`).
- Tests run under Vitest in a Node environment — no DOM. Only pure modules get unit tests; DOM/`app.ts` code is verified by `tsc --noEmit` + `npm run build` + manual checks.
- Commit messages: single line, no `Co-Authored-By`. Stage only the paths each task touches (never `git add -A`).
- Token format is symmetric and clamps to zero: `DD:HH:MM:SS` (≥ 1 day), `HH:MM:SS` (< 1 day), `MM:SS` (< 1 hour); never negative.
- DRY / YAGNI / TDD. No months/years unit. No new keyboard shortcuts.

---

## File Structure

- `src/types.ts` — add `CountdownMoment`; extend `CountdownDoc` with `moments`.
- `src/config/countdownStore.ts` — default `moments: []`, sanitize/clone/reset for moments.
- `src/sim/tokens.ts` — `TokenContext.moments`, extended grammar, `{countup}` + `:NAME` resolution, `momentHint` helper.
- `src/app.ts` — build the `moments` record in `resolveMessageText`; add `getMomentNames`; pass it to the editors.
- `src/ui/countdownEditor.ts` — named-moments list UI.
- `src/ui/introEditor.ts`, `src/ui/messagesEditor.ts` — hint hover from `getMomentNames`.
- `test/countdownStore.test.ts`, `test/tokens.test.ts` — new cases.

---

## Task 1: Data model + store (named moments)

**Files:**
- Modify: `src/types.ts` (the `CountdownDoc` interface)
- Modify: `src/config/countdownStore.ts`
- Test: `test/countdownStore.test.ts`

**Interfaces:**
- Produces: `interface CountdownMoment { name: string; targetMs: number | null }`; `CountdownDoc { targetMs: number | null; moments: CountdownMoment[] }`; `sanitizeCountdown(raw: unknown): CountdownDoc`; `cloneCountdown(d: CountdownDoc): CountdownDoc`; `DEFAULT_COUNTDOWN` with `moments: []`.

- [ ] **Step 1: Write the failing tests**

Append to `test/countdownStore.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import {
  sanitizeCountdown,
  cloneCountdown,
  DEFAULT_COUNTDOWN,
  CountdownStore,
} from "../src/config/countdownStore.ts";

describe("sanitizeCountdown — named moments", () => {
  it("migrates an old { targetMs } blob to an empty moments list", () => {
    expect(sanitizeCountdown({ targetMs: 123 })).toEqual({ targetMs: 123, moments: [] });
  });

  it("keeps valid moments and clamps negative targets to 0", () => {
    const doc = sanitizeCountdown({
      targetMs: null,
      moments: [{ name: "launch", targetMs: 1000 }, { name: "past", targetMs: -5 }],
    });
    expect(doc.moments).toEqual([
      { name: "launch", targetMs: 1000 },
      { name: "past", targetMs: 0 },
    ]);
  });

  it("strips : { } from names and trims whitespace", () => {
    const doc = sanitizeCountdown({ moments: [{ name: "  la:un{ch}  ", targetMs: 5 }] });
    expect(doc.moments).toEqual([{ name: "launch", targetMs: 5 }]);
  });

  it("drops empty-named moments and de-dupes keeping the first", () => {
    const doc = sanitizeCountdown({
      moments: [
        { name: "", targetMs: 1 },
        { name: "a", targetMs: 2 },
        { name: "a", targetMs: 3 },
      ],
    });
    expect(doc.moments).toEqual([{ name: "a", targetMs: 2 }]);
  });

  it("nulls a non-numeric moment target", () => {
    const doc = sanitizeCountdown({ moments: [{ name: "x", targetMs: "soon" }] });
    expect(doc.moments).toEqual([{ name: "x", targetMs: null }]);
  });
});

describe("cloneCountdown", () => {
  it("deep-copies the moments array", () => {
    const src = { targetMs: null, moments: [{ name: "a", targetMs: 1 }] };
    const copy = cloneCountdown(src);
    copy.moments[0]!.name = "b";
    expect(src.moments[0]!.name).toBe("a");
  });
});

describe("CountdownStore.reset — moments", () => {
  it("clears both the default target and moments", () => {
    const s = new CountdownStore();
    s.set({ targetMs: 5, moments: [{ name: "a", targetMs: 1 }] });
    expect(s.reset()).toEqual({ targetMs: null, moments: [] });
    expect(DEFAULT_COUNTDOWN.moments).toEqual([]);
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/countdownStore.test.ts`
Expected: FAIL — `moments` is not a property of the returned doc / type errors on `CountdownMoment`.

- [ ] **Step 3: Extend the types**

In `src/types.ts`, replace the `CountdownDoc` interface with:

```ts
/** A named instant referenced by {countdown:name} / {countup:name}. */
export interface CountdownMoment {
  /** Unique, non-empty label used in the token (no : { } characters). */
  name: string;
  /** Target instant as epoch ms, or null when unset (⇒ 00:00). */
  targetMs: number | null;
}

/** The countdown/countup targets, persisted to localStorage. */
export interface CountdownDoc {
  /** Default (unnamed) target for bare {countdown}/{countup}. null = unset (shows 00:00). */
  targetMs: number | null;
  /** Named moments, order preserved. */
  moments: CountdownMoment[];
}
```

- [ ] **Step 4: Implement moments in the store**

Replace the body of `src/config/countdownStore.ts` with:

```ts
import type { CountdownDoc, CountdownMoment } from "../types.ts";
import { text, capArray } from "./sanitize.ts";
import { clamp } from "../util/math.ts";

const STORAGE_KEY = "mx-countdown";
// Largest instant a JS Date can represent (±8.64e15 ms); guards against absurd stored values.
const MAX_TIME_MS = 8.64e15;
const MAX_MOMENTS = 12;
const MAX_NAME_LEN = 40;

export const DEFAULT_COUNTDOWN: CountdownDoc = { targetMs: null, moments: [] };

/** Deep copy so callers can mutate a working draft without touching shared state. */
export function cloneCountdown(d: CountdownDoc): CountdownDoc {
  return { targetMs: d.targetMs, moments: d.moments.map((m) => ({ ...m })) };
}

/** A finite epoch-ms clamped to a representable Date, or null for anything else. */
function sanitizeTarget(raw: unknown): number | null {
  return typeof raw === "number" && Number.isFinite(raw) ? clamp(raw, 0, MAX_TIME_MS) : null;
}

/** Trim a name and strip the characters that would break token parsing. */
function sanitizeName(raw: unknown): string {
  return text(raw, MAX_NAME_LEN).replace(/[:{}]/g, "").trim();
}

/** Coerce a moments array: drop empty names, de-dupe (first wins), clamp targets, cap length. */
function sanitizeMoments(raw: unknown): CountdownMoment[] {
  const seen = new Set<string>();
  const out: CountdownMoment[] = [];
  for (const item of capArray(raw, MAX_MOMENTS)) {
    const r = (typeof item === "object" && item !== null ? item : {}) as Record<string, unknown>;
    const name = sanitizeName(r.name);
    if (!name || seen.has(name)) continue;
    seen.add(name);
    out.push({ name, targetMs: sanitizeTarget(r.targetMs) });
  }
  return out;
}

/** Coerce arbitrary parsed JSON into a valid CountdownDoc. */
export function sanitizeCountdown(raw: unknown): CountdownDoc {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  return { targetMs: sanitizeTarget(r.targetMs), moments: sanitizeMoments(r.moments) };
}

/** localStorage-backed store for the user's {countdown}/{countup} targets. */
export class CountdownStore {
  private doc: CountdownDoc;

  constructor() {
    this.doc = this.load();
  }

  private load(): CountdownDoc {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return cloneCountdown(DEFAULT_COUNTDOWN);
      return sanitizeCountdown(JSON.parse(raw) as unknown);
    } catch {
      return cloneCountdown(DEFAULT_COUNTDOWN);
    }
  }

  get(): CountdownDoc {
    return cloneCountdown(this.doc);
  }

  set(doc: CountdownDoc): void {
    this.doc = sanitizeCountdown(doc);
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(this.doc));
    } catch {
      /* storage may be unavailable (private mode) — ignore */
    }
  }

  reset(): CountdownDoc {
    this.doc = cloneCountdown(DEFAULT_COUNTDOWN);
    try {
      localStorage.removeItem(STORAGE_KEY);
    } catch {
      /* ignore */
    }
    return this.get();
  }
}
```

Note: `text` and `capArray` already exist in `src/config/sanitize.ts` (used by `messagesStore.ts`).

- [ ] **Step 5: Run the tests to verify they pass**

Run: `npx vitest run test/countdownStore.test.ts`
Expected: PASS (the new cases plus the existing ones).

- [ ] **Step 6: Typecheck**

Run: `npx tsc --noEmit`
Expected: PASS. (This confirms `countdownEditor.ts`/`app.ts` still compile against the extended `CountdownDoc` — the added `moments` field is required, so watch for any object literal missing it; if `tsc` flags `countdownEditor.ts` or `app.ts`, that's fixed in Tasks 3–4, so it is acceptable to proceed only if the sole errors are in those two files. If so, note them and continue.)

- [ ] **Step 7: Commit**

```bash
git add src/types.ts src/config/countdownStore.ts test/countdownStore.test.ts
git commit -m "Add named moments to CountdownDoc/CountdownStore"
```

---

## Task 2: Token resolver — {countup}, named moments, momentHint

**Files:**
- Modify: `src/sim/tokens.ts`
- Test: `test/tokens.test.ts`

**Interfaces:**
- Consumes: `formatCountdown`, `strftime`, `DEFAULT_USER_NAME` (already in `tokens.ts`).
- Produces: `TokenContext` gains `moments?: Record<string, number | null>`; `resolveTokens` handles `{countup}`, `{countdown:NAME}`, `{countup:NAME}`; new `momentHint(names: string[]): string`.

- [ ] **Step 1: Write the failing tests**

Append to `test/tokens.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { resolveTokens, momentHint } from "../src/sim/tokens.ts";

// Build an epoch-ms from local components so assertions are timezone-independent.
const AT = (y: number, mo: number, d: number, h: number, mi: number, s = 0): number =>
  new Date(y, mo - 1, d, h, mi, s).getTime();

describe("resolveTokens — countup & named moments", () => {
  const now = AT(2026, 7, 1, 12, 0, 0);

  it("{countup} mirrors {countdown} for the same delta", () => {
    const target = now - 3_661_000; // 1h 1m 1s ago
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: target })).toBe("01:01:01");
  });

  it("{countdown:NAME} and {countup:NAME} resolve via the moments record", () => {
    const ctx = {
      name: "",
      nowMs: now,
      countdownTargetMs: null,
      moments: { launch: now + 60_000, born: now - 120_000 },
    };
    expect(resolveTokens("{countdown:launch}", ctx)).toBe("01:00");
    expect(resolveTokens("{countup:born}", ctx)).toBe("02:00");
  });

  it("an unknown name resolves to 00:00", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: {} };
    expect(resolveTokens("{countdown:nope}", ctx)).toBe("00:00");
  });

  it("countup on a future moment clamps to 00:00", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: { soon: now + 60_000 } };
    expect(resolveTokens("{countup:soon}", ctx)).toBe("00:00");
  });

  it("trims the captured name", () => {
    const ctx = { name: "", nowMs: now, countdownTargetMs: null, moments: { launch: now + 60_000 } };
    expect(resolveTokens("{countdown: launch }", ctx)).toBe("01:00");
  });

  it("bare tokens use the default target; null default → 00:00", () => {
    expect(resolveTokens("{countdown}", { name: "", nowMs: now, countdownTargetMs: null })).toBe("00:00");
    expect(resolveTokens("{countup}", { name: "", nowMs: now, countdownTargetMs: now - 60_000 })).toBe("01:00");
  });
});

describe("momentHint", () => {
  it("lists names as tokens", () => {
    expect(momentHint(["launch", "newyear"])).toBe(
      "Available: {countdown:launch}, {countdown:newyear} — also {countup:…}",
    );
  });

  it("handles the empty case", () => {
    expect(momentHint([])).toBe("No named moments yet.");
  });
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `npx vitest run test/tokens.test.ts`
Expected: FAIL — `{countup}` renders literally / `momentHint` is not exported.

- [ ] **Step 3: Extend `TokenContext`**

In `src/sim/tokens.ts`, add the `moments` field to the interface (leave the other fields as-is):

```ts
export interface TokenContext {
  /** Viewer name for `{name}` (blank falls back to DEFAULT_USER_NAME). */
  name: string;
  /** Current wall-clock, epoch ms — drives `{time}`/`{countdown}`/`{countup}`. */
  nowMs: number;
  /** Default target for bare `{countdown}`/`{countup}`, epoch ms, or null when unset. */
  countdownTargetMs: number | null;
  /** Named moments, name → target epoch ms (null = unset). Omitted ⇒ no named moments. */
  moments?: Record<string, number | null>;
}
```

- [ ] **Step 4: Extend the grammar and resolver**

In `src/sim/tokens.ts`, replace the `TOKEN_RE` constant and the `resolveTokens` function with:

```ts
// One pass over the text: {name}, {time[:FORMAT]}, {countdown[:NAME]}, {countup[:NAME]}.
// Group 1 = kind, group 2 = optional argument (a strftime format for time, a moment name otherwise).
// Unknown {foo} is left as-is.
const TOKEN_RE = /\{(name|time|countdown|countup)(?::([^}]*))?\}/g;

/** Substitute all supported tokens in `text` using `ctx`. Pure — unknown tokens pass through. */
export function resolveTokens(text: string, ctx: TokenContext): string {
  const moments = ctx.moments ?? {};
  return text.replace(TOKEN_RE, (_whole, kind: string, arg: string | undefined) => {
    if (kind === "name") return ctx.name.trim() || DEFAULT_USER_NAME;
    if (kind === "time") return strftime(new Date(ctx.nowMs), arg !== undefined ? arg : "%H:%M");
    // kind === "countdown" | "countup": a NAME selects a moment, else the default target.
    const target = arg !== undefined ? moments[arg.trim()] ?? null : ctx.countdownTargetMs;
    if (target === null) return formatCountdown(0);
    return formatCountdown(kind === "countup" ? ctx.nowMs - target : target - ctx.nowMs);
  });
}

/** UI copy: the list of available moment names as ready-to-type tokens (for the editors' hover). */
export function momentHint(names: string[]): string {
  if (names.length === 0) return "No named moments yet.";
  const list = names.map((n) => `{countdown:${n}}`).join(", ");
  return `Available: ${list} — also {countup:…}`;
}
```

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `npx vitest run test/tokens.test.ts`
Expected: PASS.

- [ ] **Step 6: Run the FULL suite to confirm no regression**

Run: `npm test`
Expected: PASS — all files, including the pre-existing `{name}`/`{time}` token tests (the grammar change is behaviour-preserving for those).

- [ ] **Step 7: Commit**

```bash
git add src/sim/tokens.ts test/tokens.test.ts
git commit -m "Resolve {countup} and named {countdown:NAME}/{countup:NAME} moments"
```

---

## Task 3: Wire the moments record into app.ts

**Files:**
- Modify: `src/app.ts` (the `resolveMessageText` closure, ~line 258; add `getMomentNames`)

**Interfaces:**
- Consumes: `resolveTokens` + `TokenContext.moments` (Task 2); `countdownStore.get().moments` (Task 1).
- Produces: `getMomentNames: () => string[]` in `app.ts` scope (consumed in Task 5).

- [ ] **Step 1: Build the moments record in the resolver**

In `src/app.ts`, replace the `resolveMessageText` definition:

```ts
  const resolveMessageText = (raw: string): string =>
    resolveTokens(raw, { name: viewerName, nowMs: Date.now(), countdownTargetMs: countdownStore?.get().targetMs ?? null });
```

with:

```ts
  // One pure resolver for every surface (intro + in-rain messages). Reads the clock, the default
  // target, and the named moments live, so {time}/{countdown}/{countup} tick without any reconfigure.
  const resolveMessageText = (raw: string): string => {
    const doc = countdownStore?.get();
    return resolveTokens(raw, {
      name: viewerName,
      nowMs: Date.now(),
      countdownTargetMs: doc?.targetMs ?? null,
      moments: Object.fromEntries((doc?.moments ?? []).map((m) => [m.name, m.targetMs])),
    });
  };
  // Current moment names, for the intro/messages editors' token hover.
  const getMomentNames = (): string[] => (countdownStore?.get().moments ?? []).map((m) => m.name);
```

- [ ] **Step 2: Typecheck**

Run: `npx tsc --noEmit`
Expected: PASS for `app.ts` and `tokens.ts`. (`getMomentNames` is unused until Task 5; `noUnusedLocals` is not enabled in this project — confirm `tsc` stays clean. If it flags `getMomentNames` as unused, proceed — Task 5 consumes it in the same working session.)

- [ ] **Step 3: Build**

Run: `npm run build`
Expected: PASS — `dist/matrixcode.html` is produced.

- [ ] **Step 4: Commit**

```bash
git add src/app.ts
git commit -m "Feed named moments into the per-frame token resolver"
```

---

## Task 4: Named-moments UI in the countdown editor

**Files:**
- Modify: `src/ui/countdownEditor.ts`

**Interfaces:**
- Consumes: `CountdownMoment` (Task 1); `ModalEditor.reorderableList`, `ModalEditor.dateTimeField`, `ModalEditor.textButton`, `ModalEditor.heading` (existing).

- [ ] **Step 1: Add the moments section**

In `src/ui/countdownEditor.ts`:

1. Extend the import to pull in the moment type:

```ts
import type { CountdownDoc, CountdownMoment } from "../types.ts";
```

2. Add a container field to the class (next to `previewEl`):

```ts
  private momentsEl: HTMLDivElement | null = null;
```

3. In `build()`, insert the moments section **after** the `dateTimeField(...)` block and **before** the preview `<p>` is appended. Add:

```ts
    this.dialog.appendChild(this.heading("h3", "Named moments"));
    const momentsHint = document.createElement("p");
    momentsHint.className = "mx-modal-hint";
    momentsHint.textContent = "Reference these as {countdown:name} or {countup:name} in the intro or a message.";
    this.dialog.appendChild(momentsHint);

    this.momentsEl = document.createElement("div");
    this.dialog.appendChild(this.momentsEl);
    this.renderMoments();

    const addMoment = this.textButton("+ Add moment", "mx-btn mx-modal-add", () => {
      this.draft.moments.push({ name: "", targetMs: null });
      this.renderMoments();
    });
    this.dialog.appendChild(addMoment);
```

4. Add the `renderMoments` method to the class (e.g. after `refreshPreview`):

```ts
  private renderMoments(): void {
    if (!this.momentsEl) return;
    this.reorderableList<CountdownMoment>({
      container: this.momentsEl,
      items: this.draft.moments,
      minItems: 0, // the list may be emptied
      renderBody: (moment, _i, remove) => {
        const name = document.createElement("input");
        name.type = "text";
        name.value = moment.name;
        name.placeholder = "name (e.g. launch)";
        name.addEventListener("input", () => {
          moment.name = name.value;
        });

        const row = document.createElement("div");
        row.className = "mx-line-timings";
        row.append(
          this.dateTimeField("When", moment.targetMs, (ms) => {
            moment.targetMs = ms;
          }),
          remove,
        );
        return [name, row];
      },
    });
  }
```

5. Update the footer's **Reset to default** handler to clear moments too:

```ts
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft.targetMs = null; this.draft.moments = []; this.build(); } },
```

- [ ] **Step 2: Typecheck**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Build**

Run: `npm run build`
Expected: PASS.

- [ ] **Step 4: Manual verification**

Run: `npm run dev` (or open `dist/matrixcode.html`). Press `H` for the panel → **⏱ Edit countdown** (or press `C`). Verify:
- A "Named moments" section shows with **+ Add moment**.
- Add a moment named `launch` with a date/time; add another named `newyear`.
- Reorder and remove work; **Save** then re-open shows them persisted.
- **Reset to default** empties both the default target and the moments list.

- [ ] **Step 5: Commit**

```bash
git add src/ui/countdownEditor.ts
git commit -m "Add named-moments list to the countdown editor"
```

---

## Task 5: Name hover in the intro & messages editors

**Files:**
- Modify: `src/ui/introEditor.ts`
- Modify: `src/ui/messagesEditor.ts`
- Modify: `src/app.ts` (pass `getMomentNames` to both editors)

**Interfaces:**
- Consumes: `momentHint` (Task 2); `getMomentNames` (Task 3).

- [ ] **Step 1: Give `IntroEditor` the moment-names getter and a hover**

In `src/ui/introEditor.ts`:

1. Add the import:

```ts
import { momentHint } from "../sim/tokens.ts";
```

2. Add a 4th constructor parameter (after `cb`):

```ts
  constructor(
    parent: HTMLElement,
    private store: IntroStore,
    private cb: IntroEditorCallbacks,
    private getMomentNames: () => string[],
  ) {
    super(parent, "Edit intro");
    this.draft = cloneIntro(DEFAULT_INTRO);
    this.linesEl = document.createElement("div");
  }
```

3. In `build()`, replace the hint block:

```ts
    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Use {name}, {time}, {time:%H:%M}, {countdown} or {countup}. ⓘ";
    hint.title = momentHint(this.getMomentNames());
    hint.style.cursor = "help";
    this.dialog.appendChild(hint);
```

- [ ] **Step 2: Give `MessagesEditor` the same**

In `src/ui/messagesEditor.ts`:

1. Add the import:

```ts
import { momentHint } from "../sim/tokens.ts";
```

2. Add a 4th constructor parameter (after `cb`):

```ts
  constructor(
    parent: HTMLElement,
    private store: MessagesStore,
    private cb: MessagesEditorCallbacks,
    private getMomentNames: () => string[],
  ) {
    super(parent, "Edit messages");
    this.draft = cloneMessages(DEFAULT_MESSAGES);
    this.listEl = document.createElement("div");
  }
```

3. In `build()`, replace the hint block:

```ts
    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Messages appear scattered inside the rain. Raise Density to make them easier to read. Use {name}, {time}, {countdown} or {countup}. ⓘ";
    hint.title = momentHint(this.getMomentNames());
    hint.style.cursor = "help";
    this.dialog.appendChild(hint);
```

- [ ] **Step 3: Pass `getMomentNames` from app.ts**

In `src/app.ts`, update the two editor constructions.

For the intro editor:

```ts
    editor = new IntroEditor(container, introStore, {
      onPreview: previewIntro,
      onSave: saveIntro,
      onCancel: () => seedOverlay(),
    }, getMomentNames);
```

For the messages editor:

```ts
    messagesEditor = new MessagesEditor(container, messagesStore, {
      onPreview: previewMessages,
      onSave: saveMessages,
      onCancel: () => {},
    }, getMomentNames);
```

- [ ] **Step 4: Typecheck**

Run: `npx tsc --noEmit`
Expected: PASS.

- [ ] **Step 5: Build**

Run: `npm run build`
Expected: PASS.

- [ ] **Step 6: Manual verification**

Run: `npm run dev`. Create a couple of named moments in **Edit countdown** (Task 4). Then:
- Open **Edit intro** (`I`): the hint line ends with `ⓘ`; hovering it shows *"Available: {countdown:launch}, {countdown:newyear} — also {countup:…}"*.
- Add an intro line `Launch in {countdown:launch}` and a second `Since launch: {countup:launch}`; Replay (`I` → ▷): the first ticks down, and (if the moment is in the past) the second ticks up.
- Open **Edit messages** (`M`): same hover; add a message `{countdown:newyear}`, enable, and confirm it ticks in the rain.
- With no moments defined, the hover reads *"No named moments yet."*

- [ ] **Step 7: Commit**

```bash
git add src/ui/introEditor.ts src/ui/messagesEditor.ts src/app.ts
git commit -m "Show available moment names on hover in the intro/messages editors"
```

---

## Final verification

- [ ] Run the full suite: `npm test` — expected: all files pass (including the new `countdownStore` and `tokens` cases and the `rainSimGolden` determinism guard).
- [ ] Type-check + single-file build: `npm run build` — expected: clean, produces `dist/matrixcode.html`.
- [ ] End-to-end manual smoke (`npm run dev`): define moments → reference `{countdown:NAME}` / `{countup:NAME}` and bare `{countdown}` / `{countup}` in both the intro and an in-rain message → confirm live ticking, the editor hover, and that Reset clears everything.

---

## Self-review notes

- **Spec coverage:** data model (Task 1), `{countup}` + named resolution + grammar + unknown-name/00:00 + name-trim (Task 2), app record wiring (Task 3), editor moments UI + reset (Task 4), hover discoverability (Task 5), tests (Tasks 1–2), migration/backward-compat (Task 1 test + preserved bare behaviour in Task 2). All spec sections map to a task.
- **Type consistency:** `CountdownMoment`/`CountdownDoc` (Task 1) are consumed unchanged in Tasks 2–5; `TokenContext.moments` (Task 2) is produced by `resolveMessageText` (Task 3); `getMomentNames` (Task 3) is consumed by the editors (Task 5); `momentHint` (Task 2) is consumed in Task 5.
- **Deliberate spec deviation:** `TokenContext.moments` is **optional** (`?`) rather than required, so existing `resolveTokens` call sites and tests that don't use named moments need no churn; behaviour is identical (absent ⇒ named tokens resolve to `00:00`).
