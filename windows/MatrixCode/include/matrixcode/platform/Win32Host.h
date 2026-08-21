#pragma once

#include <cstdint>
#include <windows.h>

namespace matrixcode::platform {

enum class HostMode { Standalone, ScreenSaver, Preview };

struct HostOptions {
  HostMode mode = HostMode::Standalone;
  HWND previewParent = nullptr;
  bool forceWarp = false;
  bool spanDisplays = false;
};

[[nodiscard]] int RunWin32Host(HINSTANCE instance, const HostOptions& options);
void EnablePerMonitorV2DpiAwareness() noexcept;

}  // namespace matrixcode::platform
