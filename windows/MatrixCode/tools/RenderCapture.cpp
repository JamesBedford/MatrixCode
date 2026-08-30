#include <filesystem>
#include <iostream>
#include <string>
#include <string_view>
#include <windows.h>
#include <objbase.h>

#include "matrixcode/core/RainSimulation.h"
#include "matrixcode/core/Settings.h"
#include "matrixcode/render/D3D11Renderer.h"

int wmain(int argc, wchar_t** argv) {
  std::filesystem::path output = L"matrixcode-windows-capture.png";
  for (int index = 1; index + 1 < argc; ++index) {
    if (std::wstring_view(argv[index]) == L"--output") output = argv[++index];
  }
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  HWND window = CreateWindowExW(
    WS_EX_TOOLWINDOW, L"STATIC", L"MatrixCode capture", WS_POPUP,
    0, 0, 1280, 720, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  if (window == nullptr) return 2;
  matrixcode::render::D3D11Renderer renderer;
  renderer.EnableFrameCapture();
  if (!renderer.Initialize(window, true)) {
    std::wcerr << L"Could not initialize WARP: " << renderer.DeviceDiagnostic() << L"\n";
    DestroyWindow(window);
    return 3;
  }
  auto settings = matrixcode::DefaultSettings();
  settings.controls.rampUpMilliseconds = 0;
  matrixcode::RainSimulation simulation(72, 40, 0x00c0ffeeu);
  simulation.WarmUp(settings.controls, 3.0);
  for (int frame = 0; frame < 300; ++frame) simulation.Update(1.0 / 60.0, settings.controls);
  const matrixcode::render::RainLayerView layer{
    simulation.State(), {}, 72, 40, 0.0f, 1.0f};
  matrixcode::render::FrameParameters parameters;
  // Fixed captures intentionally use the selected palette without live holiday overrides.
  parameters.controls = settings.controls;
  parameters.palette = matrixcode::PaletteForControls(settings.controls);
  parameters.cellPixels = 18.0f;
  // Exercise fractional grid-to-target alignment, where discontinuous atlas
  // derivatives otherwise reveal cell-sized mip seams around bright glyphs.
  parameters.adaptiveScale = 0.75f;
  parameters.elapsedSeconds = 8.0f;
  if (!renderer.Render(std::span<const matrixcode::render::RainLayerView>(&layer, 1), parameters) ||
      !renderer.CapturePng(output)) {
    std::wcerr << L"Capture failed: " << renderer.DeviceDiagnostic() << L"\n";
    DestroyWindow(window);
    return 4;
  }
  DestroyWindow(window);
  if (SUCCEEDED(com)) CoUninitialize();
  std::wcout << L"Wrote " << output.c_str() << L"\n";
  return 0;
}
