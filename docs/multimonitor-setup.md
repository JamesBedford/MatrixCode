# Multi-monitor mode

Choose **Multi-monitor** next to the **Fullscreen** button to fan the rain out
across *every* connected monitor: one
fullscreen window per display, all rendering one continuous rain that respects
your physical monitor arrangement (a column that falls off the bottom of one
screen reappears on the screen below it; side-by-side screens line up). Press
**Escape** (or close any window) to end the show everywhere at once.
The controls remain available only on the centremost display, so the rest of
the wall stays clean while live rain settings can still be adjusted.

- Double-click still toggles ordinary single-monitor fullscreen; `F` does too.
- Triple-clicking the rain is a shortcut for the **Multi-monitor** button.
- On a single monitor — or any non-Chromium browser — multi-monitor mode falls
  back to ordinary fullscreen.

## Requirements

This uses the **Window Management API**, which only exists in **Chromium**
browsers (Chrome / Edge) — not Safari or Firefox. It also needs a *secure
context*; `http://localhost` and any `https://` origin qualify (a `file://` URL
does **not** persist the permission, so serve the page rather than opening the
file directly).

## One-time Chrome setup (for the seamless one-click experience)

Without these, the show still works but each extra window opens full-bleed and
needs one click to go truly fullscreen. With them, the **Multi-monitor** button
puts true fullscreen on every monitor instantly; the triple-click shortcut
behaves the same way.

1. **Allow pop-ups for the site.** Starting multi-monitor mode opens one window per
   other monitor; Chrome blocks multiple pop-ups by default. Open the site, then
   Chrome → the pop-up-blocked icon in the address bar (or *Site settings* →
   *Pop-ups and redirects*) → **Allow** for this origin (e.g.
   `http://localhost:5188`).

2. **Allow automatic fullscreen** via Chrome policy, so each window enters true
   fullscreen without its own click. In a terminal:

   ```sh
   defaults write com.google.Chrome AutomaticFullscreenAllowedForUrls -array \
     "http://localhost:5188" "https://your-production-host"
   ```

   Then **fully quit and reopen** Chrome and confirm the policy shows up at
   `chrome://policy` (search for `AutomaticFullscreenAllowedForUrls`). Replace the
   URLs with wherever you serve the app. To undo:
   `defaults delete com.google.Chrome AutomaticFullscreenAllowedForUrls`.

3. **Grant the Window Management permission.** The first multi-monitor launch prompts for
   *"… wants to manage windows across your displays"* — click **Allow**. (The app
   pre-fetches screen details on later visits so the launch gesture isn't spent
   on the prompt; choose **Multi-monitor** again right after granting it.)

## How it works

All windows share one origin, so they coordinate with almost no messaging. The
controller window enumerates the displays, builds a single virtual grid spanning
their bounding box, and opens one window per other display — each carrying its
slice of the grid (plus a shared random seed and a `Date.now()` epoch) in the URL
hash. Every window runs the *same* deterministic simulation over the full virtual
grid, stepped in a fixed timestep against that shared epoch, and renders only its
own slice. Same seed + same clock ⇒ pixel-aligned, glyph-identical seams, with no
per-frame data crossing windows. A single `BroadcastChannel` is used only to end
the show on every window together. See `src/multimonitor/multiMonitorGrid.ts` and
`src/multimonitor/multiMonitorFullscreen.ts`.
