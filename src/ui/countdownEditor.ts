import type { CountdownDoc } from "../types.ts";
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

    const preview = document.createElement("p");
    preview.className = "mx-modal-hint";
    this.previewEl = document.createElement("span");
    preview.append("Preview: ", this.previewEl);
    this.dialog.appendChild(preview);
    this.refreshPreview();

    this.dialog.appendChild(this.footer([
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft.targetMs = null; this.build(); } },
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
