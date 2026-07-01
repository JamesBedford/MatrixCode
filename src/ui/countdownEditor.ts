import type { CountdownDoc, CountdownMoment } from "../types.ts";
import { CountdownStore, DEFAULT_COUNTDOWN, cloneCountdown } from "../config/countdownStore.ts";
import { resolveTokens } from "../sim/tokens.ts";
import { ModalEditor } from "./modalKit.ts";

export interface CountdownEditorCallbacks {
  /** Persist the draft target. */
  onSave: (draft: CountdownDoc) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

/** Centered modal for setting the `{countdown}` target date & time. Built on the ModalEditor kit. */
export class CountdownEditor extends ModalEditor {
  private draft: CountdownDoc;
  private previewEl: HTMLSpanElement | null = null;
  private momentsEl: HTMLDivElement | null = null;
  private previewTimer: number | null = null;

  constructor(parent: HTMLElement, private store: CountdownStore, private cb: CountdownEditorCallbacks) {
    super(parent, "Edit countdown");
    this.draft = cloneCountdown(DEFAULT_COUNTDOWN);
  }

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.show();
    this.startPreview();
  }

  protected requestClose(): void {
    this.cancel();
  }

  private cancel(): void {
    this.hide();
    this.cb.onCancel();
  }

  private save(): void {
    this.hide();
    this.cb.onSave(cloneCountdown(this.draft));
  }

  protected build(): void {
    this.dialog.replaceChildren();

    this.dialog.appendChild(this.heading("h2", "Edit countdown"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Counts down to this date & time. Use {countdown} in the intro or a message.";
    this.dialog.appendChild(hint);

    this.dialog.appendChild(
      this.dateTimeField("Target date & time", this.draft.targetMs, (ms) => {
        this.draft.targetMs = ms;
        this.refreshPreview();
      }),
    );

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

    const preview = document.createElement("p");
    preview.className = "mx-modal-hint";
    this.previewEl = document.createElement("span");
    preview.append("Preview: ", this.previewEl);
    this.dialog.appendChild(preview);
    this.refreshPreview();

    this.dialog.appendChild(this.footer([
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft.targetMs = null; this.draft.moments = []; this.build(); } },
      { label: "Cancel", onClick: () => this.cancel() },
      { label: "Save", onClick: () => this.save() },
    ]));
  }

  /** Show the current {countdown}/{time} so setting a target is tangible; refreshed once a second while open. */
  private refreshPreview(): void {
    if (!this.previewEl) return;
    this.previewEl.textContent = resolveTokens("{countdown} · {time}", {
      name: "",
      nowMs: Date.now(),
      countdownTargetMs: this.draft.targetMs,
    });
  }

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

  private startPreview(): void {
    this.clearPreviewTimer();
    this.previewTimer = window.setInterval(() => this.refreshPreview(), 1000);
  }

  private clearPreviewTimer(): void {
    if (this.previewTimer !== null) {
      clearInterval(this.previewTimer);
      this.previewTimer = null;
    }
  }

  protected override hide(): void {
    this.clearPreviewTimer();
    super.hide();
  }

  override destroy(): void {
    this.clearPreviewTimer();
    super.destroy();
  }
}
