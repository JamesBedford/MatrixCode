# Intro Text Editor — Design

## Goal

Let the user customise the typed "Wake up, Neo…" intro from within the site. A new **✎ Edit intro** button (next to **▷ Replay intro** in the controls panel) opens a centered modal where the user can:

- Edit each line's text.
- Add, remove, and reorder lines.
- Set, per line, how long it is shown ("hold") and how long the blank pause is before the next line starts.
- Adjust global typing speed, start delay, and fade-out.
- Preview the draft, then Save (persisted) or Cancel (discarded). Reset to default is available.

Customisations persist across reloads via `localStorage`.

## Approach

A dedicated, testable intro store plus a modal editor, mirroring the existing `ControlsStore` / `ControlsPanel` split. Rejected alternatives:

- **Fold the script into `ControlsStore`** — that store is a flat scalar store mirrored into the URL query string; an array of lines with per-line timings doesn't fit the URL-param model and would bloat it, breaking its single-purpose design.
- **No store; editor writes straight to the overlay with persistence inline in `app.ts`** — tangles sanitize/persistence into `app.ts` and isn't unit-testable.

## Data model — `src/sim/messageOverlay.ts`

`MessageLine` gains per-line timing:

```ts
interface MessageLine {
  text: string;    // may contain the {name} token
  holdMs: number;  // how long the fully-typed line stays before clearing
  pauseMs: number; // blank gap (cursor only) before the next line types; ignored on the last line
}
```

`holdMs` is **removed** from `TypeConfig`, which keeps the global settings:

```ts
interface TypeConfig {
  charMs: number;       // typing speed, ms per character
  startDelayMs: number; // blank lead-in before the first line
  fadeOutMs: number;    // fade after the final line's hold
  blinkMs: number;      // cursor blink period (not user-facing)
}
```

`computeTimeline` and `totalDuration` are rewritten for the per-line model:

- Phases: `startDelay` → for each line `[ type (text.length × charMs) → hold (line.holdMs) → pause (line.pauseMs, blank text + blinking cursor) ]` → `fadeOut` (showing the last line's full text).
- `pauseMs` is the blank gap **between** lines and is skipped for the last line.
- During a pause, `visibleText` is `""`, `opacity` is `1`, and the cursor blinks; `lineIndex` stays on the line whose pause it is.

Default script uses a `{name}` token so dynamic naming keeps working in custom scripts:

```ts
const DEFAULT_LINES: MessageLine[] = [
  { text: "Wake up, {name}...",        holdMs: 2800, pauseMs: 0 },
  { text: "The Matrix has you...",     holdMs: 2800, pauseMs: 0 },
  { text: "Follow the white rabbit.",  holdMs: 2800, pauseMs: 0 },
  { text: "Knock, knock, {name}.",     holdMs: 2800, pauseMs: 0 },
];
```

`pauseMs` defaults to `0` so the out-of-the-box intro is **visually identical to today's** (lines run back-to-back). A pure helper substitutes the token at play time:

```ts
function resolveLines(lines: MessageLine[], name: string): MessageLine[]; // replaces every {name} with name
```

`MessageOverlay` gains `setScript(lines: MessageLine[], cfg: TypeConfig): void` so the script can change at runtime without rebuilding the overlay. The overlay itself stays name-agnostic — callers pass already-resolved lines.

## Persistence — `src/config/introStore.ts` (new)

```ts
interface IntroScript {
  lines: MessageLine[];
  charMs: number;
  startDelayMs: number;
  fadeOutMs: number;
}
```

(`blinkMs` is not user-facing and stays at its default; `TypeConfig` is reconstructed as `{ ...stored, blinkMs: DEFAULT }`.)

`IntroStore` exposes `get()`, `set(script)`, and `reset()`, backed by `localStorage` key `mx-intro`. A `sanitize` function:

- Clamps every number to sane ranges: `charMs` (e.g. 10–500), `holdMs`/`pauseMs` (0–20000), `startDelayMs`/`fadeOutMs` (0–10000).
- Caps line count (~12) and per-line text length (~120 chars).
- Coerces each line to `{ text, holdMs, pauseMs }`, dropping malformed entries.
- Falls back to defaults on missing/malformed JSON or unavailable storage.

The module is pure aside from the thin `localStorage` wrapper, so `sanitize`, defaults, and round-trips are unit-testable.

## Editor modal — `src/ui/introEditor.ts` (new)

A class like `ControlsPanel`. Builds a centered modal over a click-catching backdrop, styled as a Matrix terminal reusing the existing theme variables (`--mx-accent-rgb`, `--mx-dim-rgb`, `--mx-panel`, …) so it recolours with the active preset.

Structure:

- **Lines** section — one row per line: `↑` / `↓` reorder buttons, single-line text input, "Show for" (seconds), "Pause after" (seconds, **disabled on the last line**), `×` remove button. A **+ Add line** button below. A small hint: "Use `{name}` for the visitor's name."
- **Timing** section — Typing speed (ms/char), Start delay (seconds), Fade out (seconds).
- **Footer** — **Reset to default** · **Cancel** · **Preview** · **Save**.

UI conventions:

- Durations are shown in **seconds** (step 0.1) and converted to/from **ms** internally; `charMs` is shown directly in ms/char.
- All editing happens on a **working copy**; Cancel / Escape / backdrop click discard it.
- Reordering or removing lines updates which line's "Pause after" is disabled (the last line never has a pause).

Callbacks to `app.ts`: `onPreview(draft)`, `onSave(draft)`, `onCancel()`. (Reset and working-copy editing are internal to the editor.)

## Wiring — `src/app.ts` + `src/ui/controlsPanel.ts`

- `PanelCallbacks` gains `onEditIntro: () => void`; `ControlsPanel` adds an **✎ Edit intro** button next to **▷ Replay intro**.
- On mount, `app.ts` constructs an `IntroStore`, loads the script, resolves `{name}` via the existing `resolveUserName()`, builds the `TypeConfig`, and seeds the overlay (`new MessageOverlay(..., { lines, config })`). The intro-on-first-visit and replay paths use this same resolved script.
- `onEditIntro` constructs/opens the `IntroEditor`, seeded from the store.
- **Preview**: hide the editor (so the centered intro is unobstructed), `resolveLines` the draft, `overlay.setScript(lines, cfg)` + `overlay.play(now)`. On the overlay's `onDone` (natural finish or skip via click/Esc), restore the editor.
- **Save**: `sanitize` → `IntroStore.set` → resolve `{name}` and `overlay.setScript` so future replays/first-visit use it → close the editor.
- Replay and Preview never set the `mx-intro-seen` flag (only first-visit autoplay does).
- **Escape coordination**: while the editor is open and **not** previewing, Escape closes the editor and is not forwarded to the intro-skip handler. During a preview the editor is hidden, so Escape skips the preview as usual and the overlay's `onDone` restores the editor.
- Panels (multi-monitor fullscreen slice windows) have no controls UI, so the editor is never constructed there — unchanged.

z-index: the modal sits above the panel (z-10), intro (z-15), and notice (z-20) — e.g. z-30. During preview the editor is hidden so the intro shows.

## Reduced motion

No special-casing: Preview and Replay behave exactly like the existing Replay path under `prefers-reduced-motion` (the loop is stopped, so a played intro won't animate). This is the current behaviour and not a regression.

## Testing

- Update `test/messageOverlay.test.ts` for the new `MessageLine` (`holdMs`/`pauseMs`) and `TypeConfig` (no `holdMs`) shapes. Add cases for: differing per-line holds, the inter-line blank pause (blank text mid-pause), no pause after the last line, `totalDuration` including pauses, and `{name}` resolution via `resolveLines`.
- New `test/introStore.test.ts`: defaults, `sanitize` clamping and caps (numbers, line count, text length), save→load round-trip, `reset`, and malformed-JSON / missing-storage fallback.

## Out of scope (YAGNI)

- Drag-and-drop reordering (↑/↓ buttons instead).
- Syncing the custom script into the URL query string or sharing via link.
- Per-line typing speed, colour, or font controls.
- Editable cursor blink period.
