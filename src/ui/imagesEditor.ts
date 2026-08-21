import type { Controls, ImageMask, ImagesDoc } from "../types.ts";
import type { ControlsStore } from "../config/controls.ts";
import {
  DEFAULT_IMAGES,
  ImagesStore,
  MAX_IMAGES,
  cloneImages,
  decodeBase64Mask,
} from "../config/imagesStore.ts";
import { imageFilesToMasks } from "../sim/imageMask.ts";
import { ModalEditor } from "./modalKit.ts";

export interface ImagesEditorCallbacks {
  onPreview: (draft: ImagesDoc) => void;
  onSave: (draft: ImagesDoc) => void;
  onCancel: () => void;
}

const PREVIEW_MAX_HIDE_MS = 8000;

/** Cross-platform editor for compact luminance masks revealed by the falling rain. */
export class ImagesEditor extends ModalEditor {
  private draft = cloneImages(DEFAULT_IMAGES);
  private listEl = document.createElement("div");
  private previewTimer: number | null = null;
  private openingControls: Controls | null = null;
  private maxVisibilityApplied = false;

  constructor(
    parent: HTMLElement,
    private readonly store: ImagesStore,
    private readonly controls: ControlsStore,
    private readonly callbacks: ImagesEditorCallbacks,
  ) {
    super(parent, "Edit images");
  }

  open(): void {
    this.draft = this.store.get();
    this.openingControls = this.controls.get();
    this.maxVisibilityApplied = false;
    this.build();
    this.show();
  }

  syncEnabled(enabled: boolean): void {
    if (!this.isOpen || this.draft.enabled === enabled) return;
    this.draft.enabled = enabled;
    this.build();
  }

  protected requestClose(): void {
    this.cancel();
  }

  private cancel(): void {
    this.clearPreviewTimer();
    if (this.maxVisibilityApplied && this.openingControls) this.controls.set(this.openingControls);
    this.hide();
    this.callbacks.onCancel();
  }

  private save(): void {
    this.clearPreviewTimer();
    this.hide();
    this.callbacks.onSave(cloneImages(this.draft));
  }

  private preview(): void {
    if (this.draft.images.length === 0) return;
    this.beginPreview();
    this.callbacks.onPreview(cloneImages({ ...this.draft, enabled: true }));
    this.clearPreviewTimer();
    const total = this.draft.appearMs + this.draft.persistenceMs + this.draft.disappearMs;
    this.previewTimer = window.setTimeout(() => {
      this.previewTimer = null;
      this.restoreFromPreview();
    }, Math.min(total + 500, PREVIEW_MAX_HIDE_MS));
  }

  private applyMaxVisibility(): void {
    this.draft = {
      ...this.draft,
      enabled: true,
      frequencyMs: 500,
      persistenceMs: 60000,
      appearMs: 0,
      disappearMs: 0,
      flickerOut: false,
      brightnessFade: false,
      imageScale: 1,
      imagePlacementJitter: 0,
    };
    this.controls.set({
      density: 90,
      rampUpMs: 0,
      trailLength: 0.45,
      trailVariation: 0.2,
      speed: 0.6,
      glyphScale: 0.7,
      glow: 0.6,
      leadBrightness: 1,
      vignette: 0,
      scanlines: false,
      allowOverlap: false,
      quality: "high",
      glyphMode: "latin",
      glyphFont: "mono",
      glyphRate: 1,
      mirror: false,
    });
    this.maxVisibilityApplied = true;
    this.build();
  }

  protected build(): void {
    this.dialog.replaceChildren();
    this.dialog.appendChild(this.heading("h2", "Edit images"));
    const hint = document.createElement("p");
    hint.className = "mx-modal-hint";
    hint.textContent =
      "Images emerge from the stationary glyph grid as illumination sweeps down it. Imported files are stored as compact 96-cell luminance masks.";
    this.dialog.appendChild(hint);

    const actions = document.createElement("div");
    actions.className = "mx-line-timings";
    const add = this.textButton(`+ Add images (${this.draft.images.length}/${MAX_IMAGES})`, "mx-btn", () => {
      const picker = document.createElement("input");
      picker.type = "file";
      picker.accept = "image/png,image/jpeg,image/gif,image/bmp,image/tiff,image/heic,image/webp,image/svg+xml";
      picker.multiple = true;
      picker.addEventListener("change", () => void this.addFiles(picker.files));
      picker.click();
    });
    add.disabled = this.draft.images.length >= MAX_IMAGES;
    actions.append(
      add,
      this.textButton("Max visibility", "mx-btn", () => this.applyMaxVisibility()),
    );
    this.dialog.appendChild(actions);

    this.listEl = document.createElement("div");
    this.dialog.appendChild(this.listEl);
    this.renderImages();

    this.dialog.appendChild(this.heading("h3", "Behaviour"));
    const behaviour = document.createElement("div");
    behaviour.className = "mx-line-timings";
    const enabled = this.toggleField("Show images", this.draft.enabled, (value) => (this.draft.enabled = value));
    enabled.title = "Show images (Shift+X)";
    behaviour.append(
      enabled,
      this.secondsField("Show one every (s)", this.draft.frequencyMs, (value) => (this.draft.frequencyMs = value)),
      this.secondsField("Each stays for (s)", this.draft.persistenceMs, (value) => (this.draft.persistenceMs = value)),
      this.secondsField("Appear over (s)", this.draft.appearMs, (value) => (this.draft.appearMs = value)),
      this.secondsField("Disappear over (s)", this.draft.disappearMs, (value) => (this.draft.disappearMs = value)),
      this.percentField("Screen width", this.draft.imageScale, (value) => (this.draft.imageScale = value)),
      this.percentField(
        "Placement randomness",
        this.draft.imagePlacementJitter,
        (value) => (this.draft.imagePlacementJitter = value),
      ),
      this.toggleField("Flicker dissolve", this.draft.flickerOut, (value) => (this.draft.flickerOut = value)),
      this.toggleField("Brightness fade", this.draft.brightnessFade, (value) => (this.draft.brightnessFade = value)),
    );
    this.dialog.appendChild(behaviour);

    this.dialog.appendChild(this.footer([
      {
        label: "Reset to default",
        className: "mx-btn mx-reset",
        onClick: () => {
          this.draft = cloneImages(DEFAULT_IMAGES);
          this.build();
        },
      },
      { label: "Cancel", onClick: () => this.cancel() },
      { label: "Preview image", onClick: () => this.preview() },
      { label: "Save", onClick: () => this.save() },
    ]));
  }

  private async addFiles(files: FileList | null): Promise<void> {
    if (!files) return;
    const masks = await imageFilesToMasks(files, MAX_IMAGES - this.draft.images.length);
    this.draft.images.push(...masks);
    this.build();
  }

  private renderImages(): void {
    this.reorderableList<ImageMask>({
      container: this.listEl,
      items: this.draft.images,
      minItems: 0,
      renderBody: (image, index, remove) => {
        const body = document.createElement("div");
        body.className = "mx-image-row";
        body.appendChild(this.thumbnail(image));
        const name = document.createElement("input");
        name.type = "text";
        name.maxLength = 80;
        name.value = image.name;
        name.addEventListener("input", () => (this.draft.images[index]!.name = name.value));
        const dimensions = document.createElement("span");
        dimensions.className = "mx-image-dimensions";
        dimensions.textContent = `${image.width}×${image.height}`;
        body.append(name, dimensions, remove);
        return [body];
      },
    });
  }

  private thumbnail(image: ImageMask): HTMLCanvasElement {
    const canvas = document.createElement("canvas");
    canvas.className = "mx-image-thumbnail";
    canvas.width = 104;
    canvas.height = 80;
    const context = canvas.getContext("2d");
    const mask = decodeBase64Mask(image.data);
    if (!context || !mask) return canvas;
    const source = document.createElement("canvas");
    source.width = image.width;
    source.height = image.height;
    const sourceContext = source.getContext("2d");
    if (!sourceContext) return canvas;
    const pixels = sourceContext.createImageData(image.width, image.height);
    for (let i = 0; i < mask.length; i++) {
      const value = mask[i]!;
      const offset = i * 4;
      pixels.data[offset] = value;
      pixels.data[offset + 1] = value;
      pixels.data[offset + 2] = value;
      pixels.data[offset + 3] = 255;
    }
    sourceContext.putImageData(pixels, 0, 0);
    context.imageSmoothingEnabled = true;
    context.imageSmoothingQuality = "high";
    context.drawImage(source, 0, 0, canvas.width, canvas.height);
    return canvas;
  }

  private clearPreviewTimer(): void {
    if (this.previewTimer !== null) {
      window.clearTimeout(this.previewTimer);
      this.previewTimer = null;
    }
  }

  override destroy(): void {
    this.clearPreviewTimer();
    super.destroy();
  }
}
