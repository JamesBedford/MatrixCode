#pragma once

#include <windows.h>

#include "matrixcode/platform/SettingsStoreWin32.h"

namespace matrixcode::platform {

class SettingsWindow final {
 public:
  [[nodiscard]] static INT_PTR ShowModal(HWND owner, SettingsStoreWin32& store);
};

}  // namespace matrixcode::platform
