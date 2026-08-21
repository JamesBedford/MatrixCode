#pragma once

#include <filesystem>
#include <string>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

class SettingsStoreWin32 final {
 public:
  SettingsStoreWin32();

  [[nodiscard]] SettingsSnapshot Load(std::wstring* diagnostic = nullptr) const;
  [[nodiscard]] bool Save(const SettingsSnapshot& settings, std::wstring* diagnostic = nullptr) const;
  [[nodiscard]] const std::filesystem::path& FilePath() const noexcept { return filePath_; }
  [[nodiscard]] static std::string DefaultViewerName();

 private:
  std::filesystem::path directory_;
  std::filesystem::path filePath_;
};

}  // namespace matrixcode::platform
