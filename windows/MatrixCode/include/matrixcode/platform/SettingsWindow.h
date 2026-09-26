#pragma once

#include <optional>
#include <string_view>

#include <windows.h>

#include "matrixcode/platform/SettingsStoreWin32.h"

namespace matrixcode::platform {

class SettingsWindow final {
 public:
  [[nodiscard]] static INT_PTR ShowModal(HWND owner, SettingsStoreWin32& store);
};

/** Label for the colour theme that the rain is drawing now, using the live local calendar. */
[[nodiscard]] std::optional<std::string_view> CurrentColorOverrideLabel();

}  // namespace matrixcode::platform
