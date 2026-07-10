import type { Controls, GlyphFont, GlyphMode } from "../types.ts";
import { DEFAULT_CONTROLS, type ControlsStore } from "../config/controls.ts";
import { GLYPH_FONT_OPTIONS } from "../config/glyphFonts.ts";
import { preferredMirrorForGlyphMode } from "../config/glyphMirror.ts";
import { ModalEditor } from "./modalKit.ts";

const GLYPH_OPTIONS: [GlyphMode, string][] = [
  ["matrix", "Matrix mix"],
  ["katakana", "Katakana"],
  ["binary", "Binary"],
  ["digits", "Digits"],
  ["latin", "Latin"],
  ["symbols", "Symbols"],
];

export class CharacterSettingsEditor extends ModalEditor {
  constructor(parent: HTMLElement, private controls: ControlsStore) {
    super(parent, "Character settings");
  }

  open(): void {
    this.build();
    this.show();
  }

  protected requestClose(): void {
    this.hide();
  }

  protected build(): void {
    const c = this.controls.get();
    this.dialog.replaceChildren();
    this.dialog.appendChild(this.heading("h2", "Characters"));

    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent = "Controls for the ambient rain glyphs. In-rain messages keep their readable character set.";
    this.dialog.appendChild(hint);

    this.dialog.appendChild(this.selectField("Character set", c.glyphMode, GLYPH_OPTIONS, (glyphMode) => {
      this.controls.set({ glyphMode, mirror: preferredMirrorForGlyphMode(glyphMode) });
      this.build();
    }));
    this.dialog.appendChild(this.selectField<GlyphFont>("Font", c.glyphFont, GLYPH_FONT_OPTIONS, (glyphFont) => {
      this.controls.set({ glyphFont });
    }));
    this.dialog.appendChild(this.rangeField("Glyph change", "glyphRate", 0, 5, 0.05, (v) => `${v.toFixed(2)}x`));
    this.dialog.appendChild(this.toggleField("Mirror glyphs", c.mirror, (mirror) => {
      this.controls.set({ mirror });
    }));

    this.dialog.appendChild(this.footer([
      {
        label: "Reset Characters",
        className: "mx-btn mx-reset",
        onClick: () => {
          this.controls.set({
            glyphMode: DEFAULT_CONTROLS.glyphMode,
            glyphFont: DEFAULT_CONTROLS.glyphFont,
            glyphRate: DEFAULT_CONTROLS.glyphRate,
            mirror: DEFAULT_CONTROLS.mirror,
          });
          this.build();
        },
      },
      { label: "Done", onClick: () => this.hide() },
    ]));
  }

  private rangeField(
    label: string,
    key: "glyphRate",
    min: number,
    max: number,
    step: number,
    fmt: (value: number) => string,
  ): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field mx-field--stacked";
    const top = document.createElement("span");
    top.textContent = label;
    const value = document.createElement("span");
    value.className = "mx-field-value";
    const input = document.createElement("input");
    input.type = "range";
    input.min = String(min);
    input.max = String(max);
    input.step = String(step);
    const current = this.controls.get()[key] as number;
    input.value = String(current);
    value.textContent = fmt(current);
    input.addEventListener("input", () => {
      const next = Number(input.value);
      if (!Number.isFinite(next)) return;
      value.textContent = fmt(next);
      this.controls.set({ [key]: next } as Pick<Controls, typeof key>);
    });
    const header = document.createElement("span");
    header.className = "mx-field-header";
    header.append(top, value);
    field.append(header, input);
    return field;
  }

  private selectField<T extends string>(
    label: string,
    value: T,
    options: [T, string][],
    onChange: (value: T) => void,
  ): HTMLElement {
    const field = document.createElement("label");
    field.className = "mx-field";
    const span = document.createElement("span");
    span.textContent = label;
    const select = document.createElement("select");
    for (const [optionValue, text] of options) {
      const option = document.createElement("option");
      option.value = optionValue;
      option.textContent = text;
      option.selected = optionValue === value;
      select.appendChild(option);
    }
    select.addEventListener("change", () => onChange(select.value as T));
    field.append(span, select);
    return field;
  }
}
