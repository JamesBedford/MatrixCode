#pragma once

#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <span>
#include <string>
#include <windows.h>

#include "matrixcode/core/Types.h"
#include "matrixcode/core/Controllers.h"

namespace matrixcode::render {

enum class DeviceKind { Hardware, Warp };

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

class D3D11Renderer final {
 public:
  D3D11Renderer();
  ~D3D11Renderer();
  D3D11Renderer(const D3D11Renderer&) = delete;
  D3D11Renderer& operator=(const D3D11Renderer&) = delete;
  D3D11Renderer(D3D11Renderer&&) noexcept;
  D3D11Renderer& operator=(D3D11Renderer&&) noexcept;

  [[nodiscard]] bool Initialize(HWND window, bool forceWarp = false);
  [[nodiscard]] bool Resize(std::uint32_t width, std::uint32_t height);
  void EnableFrameCapture(bool enabled = true) noexcept;
  [[nodiscard]] bool Render(std::span<const RainLayerView> layers, const FrameParameters& parameters);
  [[nodiscard]] bool CapturePng(const std::filesystem::path& output) const;
  [[nodiscard]] HRESULT ProbeOcclusion() noexcept;
  void Suspend() noexcept;
  void Resume() noexcept;

  [[nodiscard]] DeviceKind Kind() const noexcept;
  [[nodiscard]] HRESULT LastError() const noexcept;
  [[nodiscard]] std::wstring DeviceDiagnostic() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace matrixcode::render
