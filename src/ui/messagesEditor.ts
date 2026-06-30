import type { MessagesDoc } from "../types.ts";
import { MessagesStore, DEFAULT_MESSAGES, cloneMessages } from "../config/messagesStore.ts";
import { ModalEditor } from "./modalKit.ts";

export interface MessagesEditorCallbacks {
  /** Fire one message immediately over the rain (the editor hides itself first). */
  onPreview: (draft: MessagesDoc) => void;
  /** Persist the draft and reconfigure the live scheduler. */
  onSave: (draft: MessagesDoc) => void;
  /** Discard the draft. */
  onCancel: () => void;
}

// Longest the modal stays hidden during a preview before it pops back (a preview is just a peek).
const PREVIEW_MAX_HIDE_MS = 6000;

/** Centered modal for editing the in-rain messages and their scheduling. Built on the ModalEditor kit. */
export class MessagesEditor extends ModalEditor {
  private listEl: HTMLDivElement;
  private draft: MessagesDoc;
  private previewTimer: number | null = null;

  constructor(parent: HTMLElement, private store: MessagesStore, private cb: MessagesEditorCallbacks) {
    super(parent, "Edit messages");
    this.draft = cloneMessages(DEFAULT_MESSAGES);
    this.listEl = document.createElement("div");
  }

  open(): void {
    this.draft = this.store.get();
    this.build();
    this.show();
  }

  protected requestClose(): void {
    this.cancel();
  }

  private cancel(): void {
    this.clearPreviewTimer();
    this.hide();
    this.cb.onCancel();
  }

  private save(): void {
    this.clearPreviewTimer();
    this.hide();
    this.cb.onSave(cloneMessages(this.draft));
  }

  private preview(): void {
    this.beginPreview(); // hide the modal so the rain message is unobstructed
    this.cb.onPreview(cloneMessages(this.draft));
    this.clearPreviewTimer();
    const hideMs = Math.min(this.draft.persistenceMs + 500, PREVIEW_MAX_HIDE_MS);
    this.previewTimer = window.setTimeout(() => {
      this.previewTimer = null;
      this.restoreFromPreview();
    }, hideMs);
  }

  private clearPreviewTimer(): void {
    if (this.previewTimer !== null) {
      clearTimeout(this.previewTimer);
      this.previewTimer = null;
    }
  }

  protected build(): void {
    this.dialog.replaceChildren();

    this.dialog.appendChild(this.heading("h2", "Edit messages"));
    this.dialog.appendChild(this.heading("h3", "Messages"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Messages appear scattered inside the rain. Raise Density to make them easier to read.";
    this.dialog.appendChild(hint);

    this.listEl = document.createElement("div");
    this.dialog.appendChild(this.listEl);
    this.renderMessages();

    const add = this.textButton("+ Add message", "mx-btn mx-modal-add", () => {
      this.draft.messages.push("");
      this.renderMessages();
    });
    this.dialog.appendChild(add);

    this.dialog.appendChild(this.heading("h3", "Behaviour"));
    const behaviour = document.createElement("div");
    behaviour.className = "mx-line-timings";
    behaviour.appendChild(this.toggleField("Show messages", this.draft.enabled, (v) => (this.draft.enabled = v)));
    behaviour.appendChild(this.secondsField("Show one every (s)", this.draft.frequencyMs, (ms) => (this.draft.frequencyMs = ms)));
    behaviour.appendChild(this.secondsField("Each stays for (s)", this.draft.persistenceMs, (ms) => (this.draft.persistenceMs = ms)));
    this.dialog.appendChild(behaviour);

    this.dialog.appendChild(this.footer([
      { label: "Reset to default", className: "mx-btn mx-reset", onClick: () => { this.draft = cloneMessages(DEFAULT_MESSAGES); this.build(); } },
      { label: "Cancel", onClick: () => this.cancel() },
      { label: "Preview", onClick: () => this.preview() },
      { label: "Save", onClick: () => this.save() },
    ]));
  }

  private renderMessages(): void {
    this.reorderableList<string>({
      container: this.listEl,
      items: this.draft.messages,
      minItems: 0, // the list may be emptied to silence messages
      renderBody: (msg, i, remove) => {
        const text = document.createElement("input");
        text.type = "text";
        text.value = msg;
        text.placeholder = "(message text)";
        text.addEventListener("input", () => (this.draft.messages[i] = text.value));

        const actions = document.createElement("div");
        actions.className = "mx-line-timings";
        actions.appendChild(remove);
        return [text, actions];
      },
    });
  }

  override destroy(): void {
    this.clearPreviewTimer();
    super.destroy();
  }
}
