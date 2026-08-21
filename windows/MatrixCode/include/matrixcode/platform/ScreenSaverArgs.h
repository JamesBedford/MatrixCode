#pragma once

#include <cstdint>
#include <span>
#include <string>

namespace matrixcode::platform {

enum class ScreenSaverMode { Configure, Run, Preview };

struct ScreenSaverArguments {
  ScreenSaverMode mode = ScreenSaverMode::Configure;
  std::uintptr_t ownerWindow = 0;
  bool valid = true;
};

[[nodiscard]] ScreenSaverArguments ParseScreenSaverArguments(
  std::span<const std::wstring> arguments) noexcept;

}  // namespace matrixcode::platform
