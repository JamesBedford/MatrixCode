import propertyCatalogJson from "../../wallpaper-engine/property-spec.json";
import { DEFAULT_CONTROLS, sanitizeControls } from "../config/controls.ts";
import {
  DEFAULT_COUNTDOWN,
  sanitizeCountdown,
} from "../config/countdownStore.ts";
import { DEFAULT_INTRO, sanitizeIntro, type IntroScript } from "../config/introStore.ts";
import { DEFAULT_MESSAGES, sanitizeMessages } from "../config/messagesStore.ts";
import { DEFAULT_USER_NAME } from "../sim/tokens.ts";
import type { Controls, CountdownDoc, MessagesDoc } from "../types.ts";

export const WALLPAPER_ENGINE_DIRECTORY_PROPERTY = "imagesdirectory";
export const MAX_WALLPAPER_ENGINE_DIRECTORY_IMAGES = 64;
export const MAX_WALLPAPER_ENGINE_DIRECTORY_CANDIDATES = 4096;
export const WALLPAPER_ENGINE_PACKAGE_MARKER = "matrixcode-wallpaper-engine";

const IMAGE_EXTENSIONS = new Set([
  ".bmp",
  ".gif",
  ".jpeg",
  ".jpg",
  ".pnga",
  ".png",
  ".svg",
  ".webp",
]);

export type WallpaperEngineDomain =
  | "controls"
  | "countdown"
  | "images"
  | "intro"
  | "messages"
  | "tokens";

export type WallpaperEnginePropertyType =
  | "bool"
  | "color"
  | "combo"
  | "directory"
  | "file"
  | "slider"
  | "textinput";

type WallpaperEnginePropertyValue = boolean | number | string;

export interface WallpaperEngineComboOption {
  label: string;
  value: string;
}

export interface WallpaperEnginePropertyDefinition {
  key: string;
  domain: WallpaperEngineDomain;
  order: number;
  text: string;
  type: WallpaperEnginePropertyType;
  value: WallpaperEnginePropertyValue;
  min?: number;
  max?: number;
  precision?: number;
  condition?: string;
  mode?: "fetchall";
  options?: WallpaperEngineComboOption[];
}

interface WallpaperEngineCatalogField
  extends Omit<WallpaperEnginePropertyDefinition, "domain" | "key" | "order" | "text" | "value"> {
  suffix: string;
  orderOffset: number;
  text: string;
  value?: WallpaperEnginePropertyValue;
  values?: WallpaperEnginePropertyValue[];
}

interface WallpaperEngineCatalogSlots {
  count: number;
  prefix: string;
  orderStart: number;
  orderStride: number;
  fields: WallpaperEngineCatalogField[];
}

interface WallpaperEngineCatalogGroup {
  key: string;
  text: string;
  order: number;
  domain: WallpaperEngineDomain;
  properties?: Array<
    Omit<WallpaperEnginePropertyDefinition, "domain"> & {
      domain?: WallpaperEngineDomain;
    }
  >;
  slots?: WallpaperEngineCatalogSlots;
}

export interface WallpaperEnginePropertyCatalog {
  version: number;
  directoryImageLimit: number;
  metadata: {
    title: string;
    description: string;
    type: "web";
    file: string;
    preview: string;
    visibility: string;
    tags: string[];
  };
  groups: WallpaperEngineCatalogGroup[];
}

export interface WallpaperEngineImageSource {
  /** Raw Windows path supplied by Wallpaper Engine. */
  path: string;
  /** Escaped URL suitable for Image.src in Wallpaper Engine's CEF runtime. */
  url: string;
  origin: "file" | "directory";
}

export interface WallpaperEngineImagesConfiguration {
  enabled: boolean;
  frequencyMs: number;
  persistenceMs: number;
  appearMs: number;
  disappearMs: number;
  flickerOut: boolean;
  brightnessFade: boolean;
  imageScale: number;
  imagePlacementJitter: number;
  sources: WallpaperEngineImageSource[];
}

export interface WallpaperEngineConfiguration {
  controls: Controls;
  intro: IntroScript;
  messages: MessagesDoc;
  countdown: CountdownDoc;
  userName: string;
  images: WallpaperEngineImagesConfiguration;
}

export interface WallpaperEnginePropertyEnvelope {
  value: unknown;
  [key: string]: unknown;
}

export type WallpaperEnginePropertyPayload = Record<
  string,
  WallpaperEnginePropertyEnvelope | undefined
>;

export interface WallpaperEngineGeneralProperties {
  fps?: unknown;
  [key: string]: unknown;
}

export interface WallpaperEnginePropertyListener {
  applyUserProperties(properties: WallpaperEnginePropertyPayload): void;
  applyGeneralProperties(properties: WallpaperEngineGeneralProperties): void;
  setPaused(isPaused: boolean): void;
  userDirectoryFilesAddedOrChanged(propertyName: string, changedFiles: string[]): void;
  userDirectoryFilesRemoved(propertyName: string, removedFiles: string[]): void;
}

export interface WallpaperEngineWindow {
  wallpaperPropertyListener?: WallpaperEnginePropertyListener;
  wallpaperRequestRandomFileForProperty?: (
    propertyName: string,
    callback: (filePath: string) => void,
  ) => void;
}

export interface WallpaperEnginePauseTransition {
  changed: boolean;
  paused: boolean;
  /** Non-zero only when a pause ends. */
  pausedDurationMs: number;
  totalPausedMs: number;
}

export interface WallpaperEngineFrameDecision {
  render: boolean;
  /** Wall time since the last emitted frame. Zero when render is false. */
  elapsedMs: number;
}

export interface WallpaperEnginePropertiesEvent {
  type: "properties";
  initial: boolean;
  changedKeys: ReadonlySet<string>;
  changedDomains: ReadonlySet<WallpaperEngineDomain>;
  snapshot: Readonly<Record<string, WallpaperEnginePropertyValue>>;
  configuration: WallpaperEngineConfiguration;
}

export interface WallpaperEngineGeneralEvent {
  type: "general";
  fps: number;
}

export interface WallpaperEnginePauseEvent {
  type: "pause";
  transition: WallpaperEnginePauseTransition;
}

export interface WallpaperEngineDirectoryEvent {
  type: "directory";
  paths: readonly string[];
  configuration: WallpaperEngineConfiguration;
}

export type WallpaperEngineEvent =
  | WallpaperEnginePropertiesEvent
  | WallpaperEngineGeneralEvent
  | WallpaperEnginePauseEvent
  | WallpaperEngineDirectoryEvent;

export interface WallpaperEngineBridge {
  readonly listener: WallpaperEnginePropertyListener;
  readonly fpsLimiter: WallpaperEngineFpsLimiter;
  readonly pauseClock: WallpaperEnginePauseClock;
  attach(handler: (event: WallpaperEngineEvent) => void): () => void;
  configuration(): WallpaperEngineConfiguration;
  propertySnapshot(): Readonly<Record<string, WallpaperEnginePropertyValue>>;
  directoryPaths(): readonly string[];
  hasInitialProperties(): boolean;
  isLikelyHosted(): boolean;
  waitForInitialProperties(timeoutMs?: number): Promise<boolean>;
}

declare global {
  interface Window extends WallpaperEngineWindow {}
}

const PROPERTY_CATALOG = propertyCatalogJson as unknown as WallpaperEnginePropertyCatalog;

function slotToken(index: number): string {
  return String(index + 1).padStart(2, "0");
}

function replaceSlotToken(text: string, slot: string): string {
  return text.replaceAll("{slot}", slot);
}

/** Expand the compact, checked-in fixed-slot catalog into the actual WPE properties. */
export function expandWallpaperEnginePropertyCatalog(
  catalog: WallpaperEnginePropertyCatalog = PROPERTY_CATALOG,
): WallpaperEnginePropertyDefinition[] {
  const out: WallpaperEnginePropertyDefinition[] = [];
  for (const group of catalog.groups) {
    for (const property of group.properties ?? []) {
      out.push({ ...property, domain: property.domain ?? group.domain });
    }
    if (!group.slots) continue;
    for (let index = 0; index < group.slots.count; index += 1) {
      const slot = slotToken(index);
      for (const field of group.slots.fields) {
        const value = field.values?.[index] ?? field.value;
        if (value === undefined) {
          throw new Error(`Missing default for ${group.slots.prefix}${slot}${field.suffix}`);
        }
        out.push({
          key: `${group.slots.prefix}${slot}${field.suffix}`,
          domain: group.domain,
          order: group.slots.orderStart + index * group.slots.orderStride + field.orderOffset,
          text: replaceSlotToken(field.text, slot),
          type: field.type,
          value,
          ...(field.min === undefined ? {} : { min: field.min }),
          ...(field.max === undefined ? {} : { max: field.max }),
          ...(field.precision === undefined ? {} : { precision: field.precision }),
          ...(field.condition === undefined
            ? {}
            : { condition: replaceSlotToken(field.condition, slot) }),
          ...(field.mode === undefined ? {} : { mode: field.mode }),
          ...(field.options === undefined ? {} : { options: field.options }),
        });
      }
    }
  }
  return out;
}

export const WALLPAPER_ENGINE_PROPERTY_DEFINITIONS =
  expandWallpaperEnginePropertyCatalog();

const PROPERTY_BY_KEY = new Map(
  WALLPAPER_ENGINE_PROPERTY_DEFINITIONS.map((property) => [property.key, property]),
);

function finiteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

function normalizePropertyValue(
  definition: WallpaperEnginePropertyDefinition,
  value: unknown,
): WallpaperEnginePropertyValue {
  switch (definition.type) {
    case "bool":
      return typeof value === "boolean" ? value : definition.value;
    case "slider":
      return finiteNumber(value)
        ? clamp(value, definition.min ?? value, definition.max ?? value)
        : definition.value;
    case "combo":
      return typeof value === "string" &&
        definition.options?.some((option) => option.value === value)
        ? value
        : definition.value;
    case "color":
      return wallpaperEngineColorToHex(value) === null ? definition.value : String(value).trim();
    case "directory":
    case "file":
    case "textinput":
      return typeof value === "string" ? value : definition.value;
  }
}

function defaultSnapshot(): Record<string, WallpaperEnginePropertyValue> {
  return Object.fromEntries(
    WALLPAPER_ENGINE_PROPERTY_DEFINITIONS.map((property) => [property.key, property.value]),
  );
}

function snapshotValue<T extends WallpaperEnginePropertyValue>(
  snapshot: Readonly<Record<string, WallpaperEnginePropertyValue>>,
  key: string,
): T {
  return snapshot[key] as T;
}

/** Convert WPE's normalized `r g b` color form to the app's #RRGGBB form. */
export function wallpaperEngineColorToHex(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const channels = value.trim().split(/\s+/).map(Number);
  if (
    channels.length !== 3 ||
    channels.some((channel) => !Number.isFinite(channel) || channel < 0 || channel > 1)
  ) {
    return null;
  }
  return `#${channels
    .map((channel) => Math.round(channel * 255).toString(16).padStart(2, "0"))
    .join("")}`.toUpperCase();
}

/** Strict local-wall-clock parser for the text fields exposed by WPE. */
export function parseWallpaperEngineLocalDate(value: unknown): number | null {
  if (typeof value !== "string") return null;
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value.trim());
  if (!match) return null;
  const [, yearText, monthText, dayText, hourText, minuteText, secondText = "0"] = match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const date = new Date(year, month - 1, day, hour, minute, second, 0);
  if (
    date.getFullYear() !== year ||
    date.getMonth() !== month - 1 ||
    date.getDate() !== day ||
    date.getHours() !== hour ||
    date.getMinutes() !== minute ||
    date.getSeconds() !== second
  ) {
    return null;
  }
  return date.getTime();
}

function rawPath(path: string): string {
  if (!/^file:\/\//i.test(path)) return path;
  try {
    const url = new URL(path);
    const decoded = decodeURIComponent(`${url.host ? `//${url.host}` : ""}${url.pathname}`);
    return /^\/[A-Za-z]:\//.test(decoded) ? decoded.slice(1) : decoded;
  } catch {
    return path.replace(/^file:\/\/+?/i, "");
  }
}

function pathIdentity(path: string): string {
  return rawPath(path).replaceAll("\\", "/").trim().toLocaleLowerCase("en-US");
}

function comparePaths(left: string, right: string): number {
  const a = pathIdentity(left);
  const b = pathIdentity(right);
  return a < b ? -1 : a > b ? 1 : left < right ? -1 : left > right ? 1 : 0;
}

export function isWallpaperEngineImagePath(path: unknown): path is string {
  if (typeof path !== "string" || !path.trim()) return false;
  const normalized = rawPath(path).replaceAll("\\", "/").toLocaleLowerCase("en-US");
  return [...IMAGE_EXTENSIONS].some((extension) => normalized.endsWith(extension));
}

/** Convert the raw host path into an escaped local URL without double-prefixing file URLs. */
export function wallpaperEngineFileUrl(path: string): string {
  if (/^file:\/\//i.test(path)) {
    try {
      return new URL(path).href;
    } catch {
      // Fall through and treat malformed input as a raw local path.
    }
  }
  const normalized = path.trim().replaceAll("\\", "/");
  const unc = normalized.startsWith("//");
  const pieces = normalized.replace(/^\/+/, "").split("/").map((piece, index) => {
    if (!unc && index === 0 && /^[A-Za-z]:$/.test(piece)) return piece;
    return encodeURIComponent(piece);
  });
  return unc ? `file://${pieces.join("/")}` : `file:///${pieces.join("/")}`;
}

/** A bounded deterministic index for WPE's incremental fetchall callbacks. */
export class WallpaperEngineDirectoryIndex {
  private readonly values = new Map<string, string>();

  constructor(
    private readonly limit = MAX_WALLPAPER_ENGINE_DIRECTORY_IMAGES,
    private readonly candidateLimit = MAX_WALLPAPER_ENGINE_DIRECTORY_CANDIDATES,
  ) {}

  addOrChange(propertyName: string, files: readonly string[]): boolean {
    if (propertyName !== WALLPAPER_ENGINE_DIRECTORY_PROPERTY) return false;
    const before = this.candidates();
    for (const file of files) {
      if (!isWallpaperEngineImagePath(file)) continue;
      const clean = file.trim();
      this.values.set(pathIdentity(clean), clean);
    }
    this.trimToCandidateLimit();
    return !samePaths(before, this.candidates());
  }

  remove(propertyName: string, files: readonly string[]): boolean {
    if (propertyName !== WALLPAPER_ENGINE_DIRECTORY_PROPERTY) return false;
    const before = this.candidates();
    for (const file of files) this.values.delete(pathIdentity(file));
    return !samePaths(before, this.candidates());
  }

  clear(): boolean {
    if (this.values.size === 0) return false;
    this.values.clear();
    return true;
  }

  paths(): string[] {
    return this.candidates().slice(0, Math.max(0, this.limit));
  }

  /** Sorted decode candidates; callers stop once 64 files have decoded successfully. */
  candidates(): string[] {
    return [...this.values.values()].sort(comparePaths);
  }

  private trimToCandidateLimit(): void {
    const keep = new Set(
      this.candidates().slice(0, Math.max(0, this.candidateLimit)).map(pathIdentity),
    );
    for (const key of this.values.keys()) {
      if (!keep.has(key)) this.values.delete(key);
    }
  }
}

function samePaths(left: readonly string[], right: readonly string[]): boolean {
  return left.length === right.length && left.every((path, index) => path === right[index]);
}

export function selectWallpaperEngineImageSources(
  directoryPaths: readonly string[],
): WallpaperEngineImageSource[] {
  const seen = new Set<string>();
  const out: WallpaperEngineImageSource[] = [];
  const add = (path: string, origin: WallpaperEngineImageSource["origin"]): void => {
    if (!isWallpaperEngineImagePath(path)) return;
    const clean = path.trim();
    const identity = pathIdentity(clean);
    if (seen.has(identity)) return;
    seen.add(identity);
    out.push({ path: clean, url: wallpaperEngineFileUrl(clean), origin });
  };
  for (const path of [...directoryPaths].sort(comparePaths)) add(path, "directory");
  return out;
}

export function wallpaperEngineConfigurationFromSnapshot(
  snapshot: Readonly<Record<string, WallpaperEnginePropertyValue>>,
  directoryPaths: readonly string[] = [],
): WallpaperEngineConfiguration {
  const controls = {
    ...DEFAULT_CONTROLS,
    ...sanitizeControls({
      speed: snapshotValue<number>(snapshot, "rainspeed"),
      density: snapshotValue<number>(snapshot, "raindensity"),
      rampUpMs: snapshotValue<number>(snapshot, "rainrampseconds") * 1000,
      trailLength: snapshotValue<number>(snapshot, "raintraillength"),
      trailVariation: snapshotValue<number>(snapshot, "raintrailvariation"),
      glyphScale: snapshotValue<number>(snapshot, "glyphscale"),
      glyphRate: snapshotValue<number>(snapshot, "glyphrate"),
      glyphMode: snapshotValue<string>(snapshot, "glyphmode"),
      glyphFont: snapshotValue<string>(snapshot, "glyphfont"),
      mirror: snapshotValue<boolean>(snapshot, "glyphmirror"),
      preset: snapshotValue<string>(snapshot, "colorpreset"),
      customColor:
        wallpaperEngineColorToHex(snapshotValue<string>(snapshot, "customcolor")) ??
        DEFAULT_CONTROLS.customColor,
      glow: snapshotValue<number>(snapshot, "glow"),
      leadBrightness: snapshotValue<number>(snapshot, "leadglow"),
      scanlines: snapshotValue<boolean>(snapshot, "scanlines"),
      vignette: snapshotValue<number>(snapshot, "vignette"),
      allowOverlap: snapshotValue<boolean>(snapshot, "allowoverlap"),
      quality: snapshotValue<string>(snapshot, "quality"),
    }),
  };

  const lines = Array.from({ length: 12 }, (_, index) => {
    const slot = slotToken(index);
    return snapshotValue<boolean>(snapshot, `intro${slot}enabled`)
      ? {
          text: snapshotValue<string>(snapshot, `intro${slot}text`),
          holdMs: snapshotValue<number>(snapshot, `intro${slot}holdseconds`) * 1000,
          pauseMs: snapshotValue<number>(snapshot, `intro${slot}pauseseconds`) * 1000,
        }
      : null;
  }).filter((line): line is NonNullable<typeof line> => line !== null);
  const intro = sanitizeIntro({
    ...DEFAULT_INTRO,
    enabled: snapshotValue<boolean>(snapshot, "introenabled"),
    charMs: snapshotValue<number>(snapshot, "introcharmilliseconds"),
    startDelayMs: snapshotValue<number>(snapshot, "introstartseconds") * 1000,
    fadeOutMs: snapshotValue<number>(snapshot, "introfadeseconds") * 1000,
    rainDuringIntro: snapshotValue<boolean>(snapshot, "intrainduring"),
    postIntroDelayMs: snapshotValue<number>(snapshot, "intropostseconds") * 1000,
    lines,
  });

  const messagePool = Array.from({ length: 12 }, (_, index) => {
    const slot = slotToken(index);
    return snapshotValue<boolean>(snapshot, `message${slot}enabled`)
      ? snapshotValue<string>(snapshot, `message${slot}text`)
      : "";
  });
  const messages = sanitizeMessages({
    ...DEFAULT_MESSAGES,
    messages: messagePool,
    enabled: snapshotValue<boolean>(snapshot, "messagesenabled"),
    frequencyMs: snapshotValue<number>(snapshot, "messagesfrequencyseconds") * 1000,
    persistenceMs: snapshotValue<number>(snapshot, "messagesholdseconds") * 1000,
    appearMs: snapshotValue<number>(snapshot, "messagesappearseconds") * 1000,
    disappearMs: snapshotValue<number>(snapshot, "messagesdisappearseconds") * 1000,
    flickerOut: snapshotValue<boolean>(snapshot, "messagesflicker"),
    brightnessFade: snapshotValue<boolean>(snapshot, "messagesbrightnessfade"),
    messageLayout: snapshotValue<string>(snapshot, "messageslayout"),
    messageDirection: snapshotValue<string>(snapshot, "messagesdirection"),
    verticalPosition: snapshotValue<number>(snapshot, "messagesposition"),
    verticalJitter: snapshotValue<number>(snapshot, "messagesjitter"),
  });

  const moments = Array.from({ length: 12 }, (_, index) => {
    const slot = slotToken(index);
    return snapshotValue<boolean>(snapshot, `moment${slot}enabled`)
      ? {
          name: snapshotValue<string>(snapshot, `moment${slot}name`),
          targetMs: parseWallpaperEngineLocalDate(
            snapshotValue<string>(snapshot, `moment${slot}targetlocal`),
          ),
        }
      : null;
  }).filter((moment): moment is NonNullable<typeof moment> => moment !== null);
  const countdown = sanitizeCountdown({
    ...DEFAULT_COUNTDOWN,
    targetMs: parseWallpaperEngineLocalDate(
      snapshotValue<string>(snapshot, "countdowntargetlocal"),
    ),
    moments,
  });

  const userName = snapshotValue<string>(snapshot, "viewername").trim().slice(0, 80) ||
    DEFAULT_USER_NAME;
  const images: WallpaperEngineImagesConfiguration = {
    enabled: snapshotValue<boolean>(snapshot, "imagesenabled"),
    frequencyMs: snapshotValue<number>(snapshot, "imagesfrequencyseconds") * 1000,
    persistenceMs: snapshotValue<number>(snapshot, "imagesholdseconds") * 1000,
    appearMs: snapshotValue<number>(snapshot, "imagesappearseconds") * 1000,
    disappearMs: snapshotValue<number>(snapshot, "imagesdisappearseconds") * 1000,
    flickerOut: snapshotValue<boolean>(snapshot, "imagesflicker"),
    brightnessFade: snapshotValue<boolean>(snapshot, "imagesbrightnessfade"),
    imageScale: snapshotValue<number>(snapshot, "imagesscale"),
    imagePlacementJitter: snapshotValue<number>(snapshot, "imagesplacementjitter"),
    sources: selectWallpaperEngineImageSources(directoryPaths),
  };

  return { controls, intro, messages, countdown, userName, images };
}

/** Tracks host pauses and supplies app-relative time with pauses removed. */
export class WallpaperEnginePauseClock {
  private paused = false;
  private pausedAtMs: number | null = null;
  private totalMs = 0;

  setPaused(paused: boolean, nowMs: number): WallpaperEnginePauseTransition {
    if (paused === this.paused) {
      return {
        changed: false,
        paused,
        pausedDurationMs: 0,
        totalPausedMs: this.totalPausedAt(nowMs),
      };
    }
    if (paused) {
      this.paused = true;
      this.pausedAtMs = nowMs;
      return { changed: true, paused: true, pausedDurationMs: 0, totalPausedMs: this.totalMs };
    }
    const duration = Math.max(0, nowMs - (this.pausedAtMs ?? nowMs));
    this.totalMs += duration;
    this.paused = false;
    this.pausedAtMs = null;
    return {
      changed: true,
      paused: false,
      pausedDurationMs: duration,
      totalPausedMs: this.totalMs,
    };
  }

  isPaused(): boolean {
    return this.paused;
  }

  totalPausedAt(nowMs: number): number {
    return this.totalMs +
      (this.paused && this.pausedAtMs !== null ? Math.max(0, nowMs - this.pausedAtMs) : 0);
  }

  activeTime(nowMs: number): number {
    return nowMs - this.totalPausedAt(nowMs);
  }
}

/** RAF-friendly limiter that preserves all elapsed simulation time between emitted frames. */
export class WallpaperEngineFpsLimiter {
  private fps = 0;
  private lastSampleMs: number | null = null;
  private thresholdSeconds = 0;
  private elapsedSinceRenderMs = 0;
  private paused = false;

  setFps(value: unknown): number {
    this.fps = finiteNumber(value) && value > 0 ? clamp(value, 1, 1000) : 0;
    this.thresholdSeconds = 0;
    return this.fps;
  }

  getFps(): number {
    return this.fps;
  }

  setPaused(paused: boolean, nowMs?: number): void {
    this.paused = paused;
    this.reset(nowMs);
  }

  reset(nowMs?: number): void {
    this.lastSampleMs = finiteNumber(nowMs) ? nowMs : null;
    this.thresholdSeconds = 0;
    this.elapsedSinceRenderMs = 0;
  }

  sample(nowMs: number): WallpaperEngineFrameDecision {
    if (!finiteNumber(nowMs)) return { render: false, elapsedMs: 0 };
    if (this.lastSampleMs === null) {
      this.lastSampleMs = nowMs;
      return { render: !this.paused, elapsedMs: 0 };
    }
    const elapsedMs = clamp(nowMs - this.lastSampleMs, 0, 1000);
    this.lastSampleMs = nowMs;
    if (this.paused) return { render: false, elapsedMs: 0 };

    this.elapsedSinceRenderMs += elapsedMs;
    if (this.fps <= 0) {
      const emitted = this.elapsedSinceRenderMs;
      this.elapsedSinceRenderMs = 0;
      return { render: true, elapsedMs: emitted };
    }

    const periodSeconds = 1 / this.fps;
    this.thresholdSeconds = Math.min(
      periodSeconds * 2,
      this.thresholdSeconds + elapsedMs / 1000,
    );
    if (this.thresholdSeconds + Number.EPSILON < periodSeconds) {
      return { render: false, elapsedMs: 0 };
    }
    this.thresholdSeconds = Math.max(0, this.thresholdSeconds - periodSeconds);
    const emitted = this.elapsedSinceRenderMs;
    this.elapsedSinceRenderMs = 0;
    return { render: true, elapsedMs: emitted };
  }
}

export interface CreateWallpaperEngineBridgeOptions {
  host?: WallpaperEngineWindow;
  now?: () => number;
  setTimer?: (handler: () => void, timeoutMs: number) => ReturnType<typeof setTimeout>;
  clearTimer?: (timer: ReturnType<typeof setTimeout>) => void;
}

/** Create and install the listener object immediately; attach the app consumer later. */
export function createWallpaperEngineBridge(
  options: CreateWallpaperEngineBridgeOptions = {},
): WallpaperEngineBridge {
  const host = options.host ?? window;
  const now = options.now ?? (() => performance.now());
  const setTimer = options.setTimer ?? ((handler, timeoutMs) => setTimeout(handler, timeoutMs));
  const clearTimer = options.clearTimer ?? ((timer) => clearTimeout(timer));
  const snapshot = defaultSnapshot();
  const directory = new WallpaperEngineDirectoryIndex(
    PROPERTY_CATALOG.directoryImageLimit,
  );
  const fpsLimiter = new WallpaperEngineFpsLimiter();
  const pauseClock = new WallpaperEnginePauseClock();
  const handlers = new Set<(event: WallpaperEngineEvent) => void>();
  const queued: WallpaperEngineEvent[] = [];
  const initialWaiters = new Set<(received: boolean) => void>();
  let receivedInitial = false;
  let receivedHostCallback = false;

  const currentConfiguration = (): WallpaperEngineConfiguration =>
    wallpaperEngineConfigurationFromSnapshot(snapshot, directory.candidates());
  const emit = (event: WallpaperEngineEvent): void => {
    if (handlers.size === 0) {
      if (queued.length === 256) queued.shift();
      queued.push(event);
      return;
    }
    for (const handler of handlers) handler(event);
  };
  const emitDirectory = (): void => {
    emit({ type: "directory", paths: directory.paths(), configuration: currentConfiguration() });
  };

  const listener: WallpaperEnginePropertyListener = {
    applyUserProperties(properties): void {
      receivedHostCallback = true;
      const initial = !receivedInitial;
      receivedInitial = true;
      const changedKeys = new Set<string>();
      const changedDomains = new Set<WallpaperEngineDomain>();
      let clearDirectory = false;
      if (typeof properties === "object" && properties !== null) {
        for (const [key, envelope] of Object.entries(properties)) {
          const definition = PROPERTY_BY_KEY.get(key);
          if (!definition || !envelope || !("value" in envelope)) continue;
          snapshot[key] = normalizePropertyValue(definition, envelope.value);
          changedKeys.add(key);
          changedDomains.add(definition.domain);
          if (key === WALLPAPER_ENGINE_DIRECTORY_PROPERTY && snapshot[key] === "") {
            clearDirectory = true;
          }
        }
      }
      if (clearDirectory) directory.clear();
      emit({
        type: "properties",
        initial,
        changedKeys,
        changedDomains,
        snapshot: { ...snapshot },
        configuration: currentConfiguration(),
      });
      for (const waiter of initialWaiters) waiter(true);
      initialWaiters.clear();
    },
    applyGeneralProperties(properties): void {
      receivedHostCallback = true;
      if (typeof properties !== "object" || properties === null || !("fps" in properties)) return;
      emit({ type: "general", fps: fpsLimiter.setFps(properties.fps) });
    },
    setPaused(isPaused): void {
      receivedHostCallback = true;
      const transition = pauseClock.setPaused(Boolean(isPaused), now());
      if (transition.changed) {
        fpsLimiter.setPaused(transition.paused);
        emit({ type: "pause", transition });
      }
    },
    userDirectoryFilesAddedOrChanged(propertyName, changedFiles): void {
      receivedHostCallback = true;
      if (Array.isArray(changedFiles) && directory.addOrChange(propertyName, changedFiles)) {
        emitDirectory();
      }
    },
    userDirectoryFilesRemoved(propertyName, removedFiles): void {
      receivedHostCallback = true;
      if (Array.isArray(removedFiles) && directory.remove(propertyName, removedFiles)) {
        emitDirectory();
      }
    },
  };
  host.wallpaperPropertyListener = listener;

  return {
    listener,
    fpsLimiter,
    pauseClock,
    attach(handler): () => void {
      handlers.add(handler);
      if (queued.length > 0) {
        const pending = queued.splice(0);
        for (const event of pending) handler(event);
      }
      return () => handlers.delete(handler);
    },
    configuration: currentConfiguration,
    propertySnapshot: () => ({ ...snapshot }),
    directoryPaths: () => directory.candidates(),
    hasInitialProperties: () => receivedInitial,
    isLikelyHosted: () =>
      receivedHostCallback ||
      typeof host.wallpaperRequestRandomFileForProperty === "function" ||
      (typeof document !== "undefined" &&
        document.querySelector(
          `meta[name="${WALLPAPER_ENGINE_PACKAGE_MARKER}"][content="1"]`,
        ) !== null),
    waitForInitialProperties(timeoutMs = 1500): Promise<boolean> {
      if (receivedInitial) return Promise.resolve(true);
      return new Promise((resolve) => {
        let settled = false;
        let timer: ReturnType<typeof setTimeout> | null = null;
        const done = (received: boolean): void => {
          if (settled) return;
          settled = true;
          if (timer !== null) clearTimer(timer);
          initialWaiters.delete(done);
          resolve(received);
        };
        timer = setTimer(() => done(false), Math.max(0, timeoutMs));
        initialWaiters.add(done);
      });
    },
  };
}
