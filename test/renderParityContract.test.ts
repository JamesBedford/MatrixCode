import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { DEFAULT_ADAPTIVE_CONFIG } from "../src/gl/adaptiveResolution.ts";
import { getPreset, PRESET_NAMES } from "../src/config/colorPresets.ts";

const read = (relativePath: string): string =>
  readFileSync(fileURLToPath(new URL(`../${relativePath}`, import.meta.url)), "utf8");

const webRenderer = read("src/gl/renderer.ts");
const webApp = read("src/app.ts");
const webAtlas = read("src/gl/glyphAtlas.ts");
const webGlyph = read("src/gl/shaders/glyph.frag.glsl");
const webBlur = read("src/gl/shaders/blur.frag.glsl");
const webComposite = read("src/gl/shaders/composite.frag.glsl");
const nativeConstants = read("macos/MatrixCodeScreenSaver/Source/MatrixCodeConstants.m");
const nativeRenderer = read("macos/MatrixCodeScreenSaver/Source/MatrixCodeMetalView.m");
const nativeMessageScheduler = read(
  "macos/MatrixCodeScreenSaver/Source/MatrixCodeMessageScheduler.m",
);
const nativeShaders = read("macos/MatrixCodeScreenSaver/Resources/MatrixCodeShaders.metal");
const nativeAdaptive = read("macos/MatrixCodeScreenSaver/Source/MatrixCodeAdaptiveResolution.m");
const nativeApp = read("macos/MatrixCodeScreenSaver/AppSource/MatrixCodeAppDelegate.m");
const windowsControllers = read("windows/MatrixCode/include/matrixcode/core/Controllers.h");
const windowsHost = read("windows/MatrixCode/src/platform/Win32Host.cpp");
const windowsRenderer = read("windows/MatrixCode/src/render/D3D11Renderer.cpp");
const windowsSettings = read("windows/MatrixCode/src/core/Settings.cpp");
const windowsShader = read("windows/MatrixCode/shaders/MatrixCode.hlsl");
const linuxHost = read("linux/MatrixCode/src/app/MatrixCodeHost.cpp");
const linuxMain = read("linux/MatrixCode/app/Main.cpp");
const linuxRenderer = read("linux/MatrixCode/src/render/OpenGLRenderer.cpp");
const linuxXScreenSaverLauncher = read("linux/MatrixCode/resources/xscreensaver/matrixcode");
const linuxAtlas = read("linux/MatrixCode/src/render/GlyphAtlas.cpp");
const linuxGlyph = read("linux/MatrixCode/shaders/glyph.frag");
const linuxBlur = read("linux/MatrixCode/shaders/blur.frag");
const linuxComposite = read("linux/MatrixCode/shaders/composite.frag");

function numericConstant(source: string, name: string): number {
  const match = source.match(new RegExp(`\\b${name}\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)f?\\b`));
  if (!match?.[1]) throw new Error(`Missing numeric constant ${name}`);
  return Number(match[1]);
}

function hex(rgb: readonly number[]): number {
  return rgb.reduce((value, channel) => (value << 8) | Math.round(channel * 255), 0);
}

function normalized(source: string): string {
  return source.replace(/\s+/g, " ");
}

function configNumber(source: string, name: string): number {
  const match = source.match(new RegExp(`(?:\\.|\\b)${name}\\s*=\\s*([0-9.]+(?:\\s*/\\s*[0-9.]+)?)`));
  if (!match?.[1]) throw new Error(`Missing config value ${name}`);
  const factors = match[1].split("/").map((part) => Number(part.trim()));
  return factors.slice(1).reduce((value, divisor) => value / divisor, factors[0]!);
}

describe("macOS/Web render parity source contract", () => {
  it("locks atlas resolution, HDR formats, bloom levels, and blur spread", () => {
    expect(numericConstant(webApp, "ATLAS_CELL_PX")).toBe(64);
    expect(numericConstant(nativeRenderer, "MatrixCodeAtlasCellPixels")).toBe(64);
    expect(numericConstant(webRenderer, "BLUR_SPREAD")).toBe(1.8);
    expect(numericConstant(nativeRenderer, "MatrixCodeBloomSpread")).toBe(1.8);

    expect(webRenderer).toContain("{ low: 1, med: 2, high: 3 }");
    expect(nativeRenderer).toContain("if ([quality isEqualToString:@\"low\"]) return 1;");
    expect(nativeRenderer).toContain("if ([quality isEqualToString:@\"med\"]) return 2;");
    expect(webRenderer).toContain("gl.RGBA16F");
    expect(webRenderer).toContain("gl.R11F_G11F_B10F");
    expect(nativeRenderer).toContain("MTLPixelFormatRGBA16Float");
    expect(nativeRenderer).toContain("MTLPixelFormatRG11B10Float");
  });

  it("keeps the collapsed Gaussian kernel byte-for-byte equivalent", () => {
    for (const name of ["w0", "w12", "w34", "o12", "o34"]) {
      expect(numericConstant(nativeShaders, name)).toBe(numericConstant(webBlur, name));
    }
  });

  it("keeps ACES, scanline, and vignette constants aligned", () => {
    for (const name of ["a", "b", "c", "d", "e"]) {
      expect(numericConstant(nativeShaders, name)).toBe(numericConstant(webComposite, name));
    }
    for (const value of ["0.15", "0.95", "0.42", "2.8"]) {
      expect(webComposite).toContain(value);
      expect(nativeShaders).toContain(value);
    }
    expect(webRenderer).toContain("params.scanlines ? 0.12 : 0");
    expect(nativeShaders).toContain("1.0 - 0.12 * (1.0 - lines)");
  });

  it("keeps every five-stop color preset identical", () => {
    for (const name of PRESET_NAMES) {
      const match = nativeConstants.match(
        new RegExp(`@\"${name}\"\\s*:\\s*@\\[([^\\]]+)\\]`),
      );
      expect(match?.[1], `native ${name} palette`).toBeDefined();
      const nativeColors = [...(match?.[1]?.matchAll(/0x([0-9A-Fa-f]{6})/g) ?? [])]
        .map((entry) => Number.parseInt(entry[1]!, 16));
      const preset = getPreset(name);
      const webColors = [preset.background, preset.tail, preset.body, preset.bright, preset.head]
        .map(hex);
      expect(nativeColors, `${name} palette`).toEqual(webColors);
    }
  });

  it("pins the richer gold palette and matching mutation sparkle", () => {
    const gold = getPreset("gold");
    expect([gold.background, gold.tail, gold.body, gold.bright, gold.head].map(hex)).toEqual([
      0x0c0800,
      0x4a3000,
      0xb8860b,
      0xffd700,
      0xfff4c2,
    ]);

    expect(numericConstant(webRenderer, "GOLD_SPARKLE_STRENGTH")).toBe(
      numericConstant(nativeRenderer, "MatrixCodeGoldSparkleStrength"),
    );
    expect(numericConstant(webGlyph, "goldSparkleBloom")).toBe(
      numericConstant(nativeShaders, "goldSparkleBloom"),
    );
    expect(normalized(webRenderer)).toContain(
      'preset.name === "gold" ? GOLD_SPARKLE_STRENGTH : 0',
    );
    expect(normalized(nativeRenderer)).toContain(
      '[preset isEqualToString:@"gold"] ? MatrixCodeGoldSparkleStrength : 0',
    );
    const normalizedWebGlyph = normalized(webGlyph);
    const normalizedNativeShaders = normalized(nativeShaders);
    expect(normalizedWebGlyph).toContain(
      "float sparklePulse = max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase));",
    );
    expect(normalizedNativeShaders).toContain(
      "float sparklePulse = max(in.isHead > 0.5 ? 0.45 : 0.0, 4.0 * in.crossfade * (1.0 - in.crossfade));",
    );
    expect(normalizedWebGlyph).toContain(
      "float goldSparkle = uGoldSparkle * sparklePulse * smoothstep(0.45, 0.95, bright);",
    );
    expect(normalizedWebGlyph).toContain("col = mix(col, uHead, goldSparkle);");
    expect(normalizedWebGlyph).toContain("baseI * (1.0 + headExtra + goldSparkle)");
    expect(normalizedWebGlyph).toContain(
      "baseI * (headExtra + goldSparkle * goldSparkleBloom)",
    );
    expect(normalizedNativeShaders).toContain(
      "float goldSparkle = uniforms.goldSparkle * sparklePulse * smoothstep(0.45, 0.95, brightness);",
    );
    expect(normalizedNativeShaders).toContain(
      "color = mix(color, uniforms.headColor, goldSparkle);",
    );
    expect(normalizedNativeShaders).toContain(
      "baseIntensity * (1.0 + headExtra + goldSparkle)",
    );
    expect(normalizedNativeShaders).toContain(
      "baseIntensity * (headExtra + goldSparkle * goldSparkleBloom)",
    );
  });

  it("requires the complete native equivalent render graph", () => {
    for (const stage of [
      "matrixSceneFragment",
      "matrixBrightPassFragment",
      "matrixBlurFragment",
      "matrixCopyFragment",
      "matrixCompositeFragment",
    ]) {
      expect(nativeShaders).toContain(stage);
    }
    for (const pipeline of [
      "brightPassPipeline",
      "blurPipeline",
      "resamplePipeline",
      "additiveCopyPipeline",
      "compositePipeline",
    ]) {
      expect(nativeRenderer).toContain(pipeline);
    }
  });

  it("keeps adaptive-resolution controller constants aligned", () => {
    const mappings = {
      targetMilliseconds: DEFAULT_ADAPTIVE_CONFIG.targetMs,
      minimumScale: DEFAULT_ADAPTIVE_CONFIG.minScale,
      step: DEFAULT_ADAPTIVE_CONFIG.step,
      emaAlpha: DEFAULT_ADAPTIVE_CONFIG.emaAlpha,
      upHeadroom: DEFAULT_ADAPTIVE_CONFIG.upHeadroom,
      downThreshold: DEFAULT_ADAPTIVE_CONFIG.downThreshold,
      cooldownFrames: DEFAULT_ADAPTIVE_CONFIG.cooldownFrames,
      warmFrames: DEFAULT_ADAPTIVE_CONFIG.warmFrames,
    };
    for (const [name, expected] of Object.entries(mappings)) {
      expect(configNumber(nativeAdaptive, name), name).toBeCloseTo(expected, 12);
    }
  });

  it("uses the same middle inked glyph for blank atlas cells", () => {
    expect(webAtlas).toContain(
      "goodFallbacks[Math.floor(goodFallbacks.length / 2)]",
    );
    expect(webAtlas).toContain("drawGlyph(chars[fallbackIndex]!, i)");
    expect(nativeRenderer).toContain(
      "inkedIndexes[inkedIndexes.count / 2].unsignedIntegerValue",
    );
    expect(nativeRenderer).toContain("drawGlyphAtIndex(glyphs[fallbackIndex], index)");
    expect(nativeRenderer).not.toContain(
      'MatrixCodeDrawReadableDigitGlyph(context, @"8", cellRect)',
    );
  });

  it("centers native glyphs with Canvas-equivalent typographic metrics", () => {
    expect(webAtlas).toContain('ctx.textAlign = "center"');
    expect(webAtlas).toContain('ctx.textBaseline = "middle"');
    expect(nativeRenderer).toContain("CTLineGetTypographicBounds");
    expect(nativeRenderer).toContain("(ascent - descent) * 0.5");
    expect(nativeRenderer).not.toContain("kCTLineBoundsUseGlyphPathBounds");
  });

  it("starts each standalone multi-monitor entry with a fresh identity", () => {
    expect(nativeApp).toContain(
      "[MatrixCodeSession freshSessionForScreen:screens.firstObject]",
    );
    expect(nativeApp).not.toContain(
      "[MatrixCodeSession sessionForScreen:screens.firstObject]",
    );
  });
});

describe("Windows/Web render parity source contract", () => {
  it("keeps the Gaussian kernel and bloom spread aligned", () => {
    for (const name of ["w0", "w12", "w34", "o12", "o34"]) {
      expect(numericConstant(windowsShader, name), name).toBeCloseTo(
        numericConstant(webBlur, name),
        6,
      );
    }
    expect(numericConstant(windowsShader, "spread")).toBe(
      numericConstant(webRenderer, "BLUR_SPREAD"),
    );
  });

  it("keeps tone mapping, scanlines, and vignette math aligned", () => {
    for (const name of ["a", "b", "c", "d", "e"]) {
      expect(numericConstant(windowsShader, name)).toBe(numericConstant(webComposite, name));
    }
    for (const value of ["0.15", "0.95", "0.42", "2.8"]) {
      expect(webComposite).toContain(value);
      expect(windowsShader).toContain(value);
    }
    expect(windowsRenderer).toContain("parameters.controls.scanlines ? 0.12f : 0.0f");
  });

  it("keeps every fixed five-stop palette identical", () => {
    for (const name of PRESET_NAMES) {
      const match = windowsSettings.match(
        new RegExp(`\\{"${name}", \\{([^}]+)\\}\\}`),
      );
      expect(match?.[1], `Windows ${name} palette`).toBeDefined();
      const windowsColors = [...(match?.[1]?.matchAll(/0x([0-9A-Fa-f]{6})/g) ?? [])]
        .map((entry) => Number.parseInt(entry[1]!, 16));
      const preset = getPreset(name);
      const webColors = [preset.background, preset.tail, preset.body, preset.bright, preset.head]
        .map(hex);
      expect(windowsColors, `${name} palette`).toEqual(webColors);
    }
  });

  it("keeps adaptive-resolution defaults aligned", () => {
    const mappings = {
      targetMilliseconds: DEFAULT_ADAPTIVE_CONFIG.targetMs,
      minimumScale: DEFAULT_ADAPTIVE_CONFIG.minScale,
      step: DEFAULT_ADAPTIVE_CONFIG.step,
      emaAlpha: DEFAULT_ADAPTIVE_CONFIG.emaAlpha,
      upHeadroom: DEFAULT_ADAPTIVE_CONFIG.upHeadroom,
      downThreshold: DEFAULT_ADAPTIVE_CONFIG.downThreshold,
      cooldownFrames: DEFAULT_ADAPTIVE_CONFIG.cooldownFrames,
      warmFrames: DEFAULT_ADAPTIVE_CONFIG.warmFrames,
    };
    for (const [name, expected] of Object.entries(mappings)) {
      expect(configNumber(windowsControllers, name), name).toBeCloseTo(expected, 12);
    }
  });

  it("keeps quality tiers and gold sparkle behavior aligned", () => {
    const normalizedWebRenderer = normalized(webRenderer);
    const normalizedWindowsRenderer = normalized(windowsRenderer);
    expect(normalizedWebRenderer).toContain("{ low: 1, med: 2, high: 3 }");
    expect(normalizedWindowsRenderer).toContain(
      "parameters.controls.quality == QualityTier::Low ? 1 : parameters.controls.quality == QualityTier::Medium ? 2 : 3",
    );
    const goldSparkleStrength = numericConstant(webRenderer, "GOLD_SPARKLE_STRENGTH");
    expect(normalizedWindowsRenderer).toContain(
      `parameters.controls.preset == "gold" ? ${goldSparkleStrength.toFixed(2)}f : 0.0f`,
    );
    const normalizedWindowsShader = normalized(windowsShader);
    for (const expression of [
      "max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase))",
      "goldSparkle * sparklePulse * smoothstep(0.45, 0.95, brightness)",
      "baseIntensity * (headExtra + sparkle * 0.35)",
    ]) {
      expect(normalizedWindowsShader).toContain(expression);
    }
  });

  it("requires every Windows render-graph shader entry point", () => {
    for (const stage of [
      "GlyphPs",
      "BrightPassPs",
      "CopyPs",
      "BlurHPs",
      "BlurVPs",
      "CompositePs",
      "OverlayPs",
    ]) {
      expect(windowsShader).toContain(stage);
      expect(windowsRenderer).toContain(`CompileShader("${stage}"`);
    }
  });

  it("keeps paused Windows token and image timelines frozen during holiday repaints", () => {
    const presentationClock = windowsHost.match(
      /double NativeHost::PresentationTimeSeconds\(\) const \{([\s\S]*?)\n\}/,
    )?.[1];
    expect(normalized(presentationClock ?? "")).toContain(
      "return timelinePauseReasons_ != 0 && timelinePauseStartSeconds_ > 0.0 ? timelinePauseStartSeconds_ : UnixSeconds();",
    );
    const tokenResolver = windowsHost.match(
      /std::string NativeHost::ResolveText\([^\n]*\) const \{([\s\S]*?)\n\}/,
    )?.[1];
    expect(tokenResolver).toContain("context.nowMilliseconds = PresentationTimeSeconds() * 1000.0;");
    expect(tokenResolver).not.toContain("UnixSeconds()");
    const renderAll = windowsHost.match(
      /void NativeHost::RenderAll\([^\n]*\) \{([\s\S]*?)\n\}/,
    )?.[1];
    expect(renderAll).toContain("const double now = PresentationTimeSeconds();");
  });

  it("checks the live Windows local date before skipping frozen frames", () => {
    const tick = windowsHost.match(/void NativeHost::Tick\(\) \{([\s\S]*?)\n\}/)?.[1] ?? "";
    const localDate = tick.indexOf("const auto localDay = ReadLocalCalendarDay(localCalendarDayCache_);");
    const moonDate = tick.indexOf("fullMoonDayCache_.ContainsFullMoon(");
    const invalidation = tick.indexOf(
      "if (renderControls.preset != renderedPreset_) staticFrameRendered_ = false;",
    );
    const frozenSkip = tick.indexOf("if (frozen && staticFrameRendered_ && !toastAnimating) return;");
    expect(localDate).toBeGreaterThanOrEqual(0);
    expect(moonDate).toBeGreaterThan(localDate);
    expect(invalidation).toBeGreaterThan(moonDate);
    expect(frozenSkip).toBeGreaterThan(invalidation);
    const calendarDay = windowsHost.match(
      /LocalCalendarDay ReadLocalCalendarDay\(LocalCalendarDayCache& cache\) \{([\s\S]*?)\n\}/,
    )?.[1] ?? "";
    expect(calendarDay).toContain("GetDynamicTimeZoneInformation(&timezone)");
    expect(calendarDay).toContain("SystemTimeToTzSpecificLocalTimeEx(&timezone, &utc, &result.date)");
    expect(calendarDay).toContain("SystemTimeToTzSpecificLocalTimeEx(&timezone, &candidateUtc, &local)");
    expect(calendarDay).toContain("LocalDayBoundaryMilliseconds(todayIndex + 1, localDayAt)");
    expect(calendarDay.indexOf("SameTimezone(*cache.timezone, timezone)")).toBeLessThan(
      calendarDay.indexOf("LocalDayBoundaryMilliseconds(todayIndex, localDayAt)"),
    );
    expect(calendarDay).not.toContain("TzSpecificLocalTimeToSystemTimeEx(");
    expect(calendarDay).not.toContain("PresentationTimeSeconds()");
  });
});

describe("Linux/Web render parity source contract", () => {
  it("keeps the message scheduler seed aligned across every implementation", () => {
    expect(webApp).toContain("const MSG_SEED = 0x5eed1e;");
    expect(nativeMessageScheduler).toContain(
      "const uint32_t MatrixCodeMessageSchedulerSeed = 0x5eed1eU;",
    );
    expect(windowsHost).toContain("constexpr std::uint32_t kMessageSeed = 0x5eed1eu;");
    expect(linuxHost).toContain("constexpr std::uint32_t kMessageSeed = 0x5eed1eu;");
  });

  it("keeps deterministic capture independent of display scale and calendar colors", () => {
    expect(numericConstant(linuxHost, "kCaptureWidth")).toBe(960);
    expect(numericConstant(linuxHost, "kCaptureHeight")).toBe(600);
    expect(linuxHost).toContain("if (IsCapture()) return settings_.controls;");
    expect(normalized(linuxHost)).toContain(
      "const float logicalPerPixel = IsCapture() ? 1.0f : static_cast<float>(1.0 / widget.devicePixelRatioF());",
    );
  });

  it("allows OpenGL ES 3 when the Qt platform exposes an ES-only implementation", () => {
    expect(linuxMain).toContain("QOpenGLContext::openGLModuleType()");
    expect(linuxMain).toContain("QSurfaceFormat::OpenGLES");
    expect(linuxMain).toContain("format.setVersion(3, usesOpenGles ? 0 : 3);");
  });

  it("uses independent state textures for every composited rain lane", () => {
    expect(linuxRenderer).toContain("std::vector<LayerTextures> layerTextures;");
    expect(linuxRenderer).toContain("LayerTextures& textures = layerTextures[layerIndex];");
    expect(linuxRenderer).toContain("const LayerTextures& textures = impl_->layerTextures[layerIndex];");
  });

  it("keeps XScreenSaver playback hosted and retries failed hardware initialization in software", () => {
    expect(linuxHost).toContain("return IsPreview() || options_.xscreensaverHosted;");
    expect(linuxHost).toContain("return IsSaver() && !options_.xscreensaverHosted;");
    expect(linuxHost).toContain("QCoreApplication::exit(kSoftwareFallbackExitCode);");
    expect(linuxHost).toContain("platform::QueryX11WindowSize(options_.parentWindowId)");
    expect(linuxXScreenSaverLauncher).toContain('if [ "${status}" -eq 75 ]; then');
    expect(linuxXScreenSaverLauncher).toContain('exec "${binary}" --software "$@"');
    expect(linuxHost).toContain("if (!widget.BeginRendererRecovery())");
    expect(linuxHost).toContain("widget.ResetRendererRecovery();");
  });

  it("honors GNOME reduced motion and never shifts a scheduler driven by frozen elapsed time", () => {
    expect(linuxHost).toContain("org.gnome.desktop.interface");
    expect(linuxHost).toContain("enable-animations");
    const shiftTimelines = linuxHost.match(
      /void MatrixCodeHost::ShiftPresentationTimelines\([^\n]*\) \{([\s\S]*?)\n\}/,
    )?.[1] ?? "";
    expect(shiftTimelines).not.toContain("messageScheduler_.ShiftTimelineBy");
  });

  it("starts load-ramped rain empty without applying that reset to embedded previews", () => {
    expect(normalized(linuxHost)).toContain(
      "if (!IsPreview() && !reducedMotion_ && settings_.controls.rampUpMilliseconds > 0.0)",
    );
    expect(linuxHost).toContain("ResetRainToEmpty(elapsedSeconds_);");
  });

  it("locks atlas resolution, HDR formats, bloom levels, and blur spread", () => {
    expect(numericConstant(linuxAtlas, "kAtlasCellPixels")).toBe(64);
    expect(numericConstant(linuxRenderer, "kBlurSpread")).toBe(
      numericConstant(webRenderer, "BLUR_SPREAD"),
    );
    expect(linuxRenderer).toContain("GL_RGBA16F");
    expect(linuxRenderer).toContain("GL_R11F_G11F_B10F");
    expect(normalized(linuxRenderer)).toContain(
      "parameters.controls.quality == QualityTier::Low ? 1u : parameters.controls.quality == QualityTier::Medium ? 2u : 3u",
    );
  });

  it("keeps the Gaussian kernel, ACES, scanlines, and vignette aligned", () => {
    for (const name of ["w0", "w12", "w34", "o12", "o34"]) {
      expect(numericConstant(linuxBlur, name), name).toBe(numericConstant(webBlur, name));
    }
    for (const name of ["a", "b", "c", "d", "e"]) {
      expect(numericConstant(linuxComposite, name), name).toBe(
        numericConstant(webComposite, name),
      );
    }
    for (const value of ["0.15", "0.95", "0.42", "2.8"]) {
      expect(linuxComposite).toContain(value);
      expect(webComposite).toContain(value);
    }
    expect(linuxRenderer).toContain("parameters.controls.scanlines ? 0.12f : 0.0f");
  });

  it("keeps the gold sparkle equations and shader-safe packed-state name", () => {
    expect(numericConstant(linuxRenderer, "kGoldSparkleStrength")).toBe(
      numericConstant(webRenderer, "GOLD_SPARKLE_STRENGTH"),
    );
    expect(numericConstant(linuxGlyph, "goldSparkleBloom")).toBe(
      numericConstant(webGlyph, "goldSparkleBloom"),
    );
    const shader = normalized(linuxGlyph);
    expect(shader).toContain(
      "float sparklePulse = max(isHead ? 0.45 : 0.0, 4.0 * phase * (1.0 - phase));",
    );
    expect(shader).toContain(
      "float goldSparkle = uGoldSparkle * sparklePulse * smoothstep(0.45, 0.95, bright);",
    );
    expect(linuxGlyph).toContain("vec4 packedState = texelFetch(uState, cell, 0);");
    expect(linuxGlyph).not.toMatch(/\bvec4\s+packed\b/);
  });

  it("uses the shared native simulation and scheduler contracts", () => {
    for (const symbol of [
      "ComputeRainLanes",
      "PlanSimulationSteps",
      "ImageScheduler",
      "MessageScheduler",
      "EffectiveControlsForLocalDate",
    ]) {
      expect(linuxHost).toContain(symbol);
    }
    expect(linuxAtlas).toContain("inkedIndexes[inkedIndexes.size() / 2]");
  });
});
