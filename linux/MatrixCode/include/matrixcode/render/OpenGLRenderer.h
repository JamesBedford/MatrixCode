#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

#include <QImage>

#include "matrixcode/core/Controllers.h"
#include "matrixcode/core/Types.h"

class QOpenGLContext;

namespace matrixcode::render {

enum class DeviceKind { Hardware, Software };

struct RainLayerView {
  std::span<const std::uint8_t> state;
  std::span<const float> brightnessBoost;
  std::uint32_t columns = 0;
  std::uint32_t rows = 0;
  float offsetCells = 0.0f;
  float weight = 1.0f;
};

struct FrameParameters {
  Controls controls;
  ColorPalette palette;
  std::string overlayText;
  std::string hudText;
  std::string toastText;
  float cellPixels = 18.0f;
  float virtualOriginX = 0.0f;
  float virtualOriginY = 0.0f;
  float logicalPerPixelX = 1.0f;
  float logicalPerPixelY = 1.0f;
  float adaptiveScale = 1.0f;
  float elapsedSeconds = 0.0f;
  float overlayOpacity = 0.0f;
  float toastOpacity = 0.0f;
  float toastOffsetDips = 0.0f;
  PresentationMode presentationMode = PresentationMode::Synchronized;
};

struct RendererDiagnostics {
  DeviceKind deviceKind = DeviceKind::Software;
  std::string vendor;
  std::string renderer;
  std::string version;
  std::string shadingLanguageVersion;
  std::string lastError;
  std::uint32_t maximumTextureSize = 0;
  bool initialized = false;
  bool openGles = false;
  bool hdrScene = false;
  bool packedFloatBloom = false;
};

/**
 * OpenGL 3.3/OpenGL ES 3 renderer for use from a Qt QOpenGLWidget.
 *
 * Every method that creates, destroys, or draws GL resources must be called on
 * the widget's GUI thread while its QOpenGLContext is current. QOpenGLWidget
 * renders into an internal framebuffer, so paintGL callers must pass
 * defaultFramebufferObject() to Render rather than assuming framebuffer zero.
 */
class OpenGLRenderer final {
 public:
  OpenGLRenderer();
  ~OpenGLRenderer();
  OpenGLRenderer(const OpenGLRenderer&) = delete;
  OpenGLRenderer& operator=(const OpenGLRenderer&) = delete;
  OpenGLRenderer(OpenGLRenderer&&) = delete;
  OpenGLRenderer& operator=(OpenGLRenderer&&) = delete;

  [[nodiscard]] bool Initialize(QOpenGLContext* context);
  void Cleanup() noexcept;
  [[nodiscard]] bool Resize(std::uint32_t backingWidth, std::uint32_t backingHeight);
  [[nodiscard]] bool Render(
    std::span<const RainLayerView> layers,
    const FrameParameters& parameters,
    std::uint32_t outputFramebuffer);

  /** Reads the most recently rendered output framebuffer and flips it to top-left image order. */
  [[nodiscard]] QImage CaptureFrame() const;

  [[nodiscard]] bool IsInitialized() const noexcept;
  [[nodiscard]] const RendererDiagnostics& Diagnostics() const noexcept;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace matrixcode::render
