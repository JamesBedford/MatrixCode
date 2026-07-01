# Named moments: `{countup}` and named countdowns

**Date:** 2026-07-01
**Status:** Approved (design)

## Context

The placeholder system (`src/sim/tokens.ts`) currently supports `{name}`, `{time}`,
`{time:FORMAT}`, and a single `{countdown}` backed by one global target
(`CountdownStore`, `mx-countdown`). Tokens resolve per-frame in both the typed intro
(`MessageOverlay`) and the in-rain messages (`MessageScheduler`) through one pure resolver
closure (`resolveMessageText` in `app.ts`).

This adds two capabilities:

1. **`{countup}`** — time *elapsed since* an instant (the mirror of `{countdown}`).
2. **Named moments** — `{countdown:NAME}` / `{countup:NAME}` referencing a user-defined set
   of named instants, so a page can show several independent timers.

A single named instant ("moment") serves both directions: e.g. a launch you count *down* to
with `{countdown:launch}` and, once it passes, count *up* from with `{countup:launch}`.

## Goals / non-goals

**Goals**
- Add `{countup}` and `{countup:NAME}` / `{countdown:NAME}`.
- Let the user manage a list of named moments (name → date/time) in the countdown editor.
- Make available names discoverable via a hover in the intro and messages editors.
- Preserve the existing bare `{countdown}` / `{countup}` behaviour and the current single
  saved target (backward compatible, no data loss).

**Non-goals**
- No months/years unit in the format (days is the largest unit, matching `{countdown}` today).
- No async/external targets. No per-moment enable flags. No new keyboard shortcuts.

## Design

### 1. Data model (`src/types.ts`, `src/config/countdownStore.ts`)

The existing single field stays as the **default** (unnamed) moment; named moments are added
alongside it:

```ts
interface CountdownMoment { name: string; targetMs: number | null }
interface CountdownDoc {
  targetMs: number | null;      // default moment — bare {countdown} / {countup}
  moments: CountdownMoment[];   // named moments, order preserved
}
```

- **Bare `{countdown}` / `{countup}`** → `targetMs` (unchanged from today).
- **`{countdown:NAME}` / `{countup:NAME}`** → the matching `moments[].targetMs`.
- **Migration is free:** an old `{ targetMs }` blob loads with `moments: []` (the sanitizer
  fills the missing key). Storage key stays `mx-countdown`; no version bump needed.
- **`reset()`** clears both `targetMs` and `moments`.

**Sanitization** (`sanitizeCountdown`): `targetMs` clamped to `[0, 8.64e15]` or null (as
today). Each moment: `name` trimmed with `:`, `{`, `}` stripped (they would break token
parsing); moments with an empty name dropped; duplicate names de-duped keeping the first;
`targetMs` clamped/nulled as for the default. `cloneCountdown` deep-copies the `moments` array.

### 2. Token grammar & resolver (`src/sim/tokens.ts`)

`TokenContext` replaces `countdownTargetMs` with the default plus a name lookup:

```ts
interface TokenContext {
  name: string;
  nowMs: number;
  countdownTargetMs: number | null;          // default moment
  moments: Record<string, number | null>;    // name -> target epoch ms
}
```

Grammar (one pass, unknown `{foo}` still passes through untouched):

```
{name}
{time} | {time:FORMAT}
{countdown} | {countdown:NAME}
{countup}   | {countup:NAME}
```

Resolution, both directions reusing the existing `formatCountdown` (which clamps ≥ 0). The
captured `NAME` is trimmed before lookup (so `{countdown: launch }` matches the moment
`launch`); a `{time:FORMAT}` capture is **not** trimmed, since spaces in a format string are
significant:

- target = NAME present ? `moments[NAME.trim()] ?? null` : `countdownTargetMs`
- `{countdown[:N]}` → `formatCountdown(target === null ? 0 : target - nowMs)`
- `{countup[:N]}`   → `formatCountdown(target === null ? 0 : nowMs - target)`

**Decisions:**
- **Unknown name** (`{countdown:typo}`, no such moment) → treated as unset → `00:00`
  (consistent with the "no target" rule). The hover keeps typos rare.
- **countup on a future moment** (or countdown on a past one) → `0` → `00:00` (clamped).
- Format stays symmetric: `DD:HH:MM:SS` when ≥ 1 day, `HH:MM:SS` when < 1 day, `MM:SS` when
  < 1 hour. Days are zero-padded to ≥ 2 and never truncated for long spans.

### 3. `app.ts` wiring

`resolveMessageText` builds the context from the store each call (already per-frame):

```ts
resolveTokens(raw, {
  name: viewerName,
  nowMs: Date.now(),
  countdownTargetMs: countdownStore?.get().targetMs ?? null,
  moments: Object.fromEntries((countdownStore?.get().moments ?? []).map(m => [m.name, m.targetMs])),
});
```

No scheduler/overlay reconfigure is needed — both surfaces read the store live, so a saved
edit takes effect on the next frame.

### 4. Countdown editor (`src/ui/countdownEditor.ts`)

Keep the existing **"Target date & time"** field (the default) at the top. Add a **"Named
moments"** section below it built on the existing `reorderableList` from `modalKit`:

- Each row: a **name** text input + a **`dateTimeField`** + the kit's remove button.
- A **"+ Add moment"** button appends `{ name: "", targetMs: null }` and re-renders.
- The live `{countdown} · {time}` preview stays.
- **Reset to default** clears the default target and empties the moments list.

Edits mutate a `draft: CountdownDoc`; **Save** persists via `store.set(draft)` (sanitized).

### 5. Name hover (`src/ui/introEditor.ts`, `src/ui/messagesEditor.ts`)

The existing token-hint line gains a hover tooltip listing the current names, e.g.:

> Available: `{countdown:launch}`, `{countdown:newyear}` — also `{countup:…}`

…or *"No named moments yet."* when the list is empty. To feed it without coupling those
editors to the store, `app.ts` passes a small `getMomentNames: () => string[]` callback into
`IntroEditor` and `MessagesEditor`; the tooltip text is rebuilt in `build()` (each open) from
the current names. Implemented as a native `title` attribute on the hint (hover = tooltip).

## Testing

- **`test/tokens.test.ts`:**
  - `{countup}` mirrors `{countdown}` for the same delta.
  - `{countdown:NAME}` / `{countup:NAME}` resolve via the `moments` record.
  - Unknown name → `00:00`; countup on a future moment → `00:00`.
  - Bare `{countdown}` / `{countup}` still use `countdownTargetMs`; null default → `00:00`.
- **`test/countdownStore.test.ts`:**
  - Moment sanitization: `:`/`{`/`}` stripped, name trimmed, empty-name dropped, duplicates
    de-duped, `targetMs` clamped/nulled.
  - Migration: an old `{ targetMs }` blob loads with `moments: []`.
  - `reset()` clears both `targetMs` and `moments`.
- The scheduler and overlay consume the injected resolver unchanged, so no new tests there;
  the existing `rainSimGolden` test continues to guard rain determinism.

## Files touched

- `src/types.ts` — `CountdownMoment`, extend `CountdownDoc`.
- `src/config/countdownStore.ts` — default, sanitize (moments), clone, reset.
- `src/sim/tokens.ts` — `TokenContext.moments`, grammar, `{countup}` + `:NAME` resolution.
- `src/app.ts` — build `moments` record in `resolveMessageText`; pass `getMomentNames` to the
  intro/messages editors.
- `src/ui/countdownEditor.ts` — named-moments list UI.
- `src/ui/introEditor.ts`, `src/ui/messagesEditor.ts` — hint hover from `getMomentNames`.
- `test/tokens.test.ts`, `test/countdownStore.test.ts` — new cases.

## Backward compatibility

Existing `mx-countdown` blobs (`{ targetMs }`) load unchanged with an empty moments list. The
bare `{countdown}` token and the single-target editor field behave exactly as before; named
moments and `{countup}` are purely additive.
