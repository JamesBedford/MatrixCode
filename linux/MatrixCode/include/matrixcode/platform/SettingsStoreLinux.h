#pragma once

#include <QString>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

class SettingsStoreLinux final {
 public:
  explicit SettingsStoreLinux(QString configDirectory = {});

  [[nodiscard]] SettingsSnapshot Load(QString* diagnostic = nullptr) const;
  [[nodiscard]] bool Save(
    const SettingsSnapshot& settings,
    QString* diagnostic = nullptr) const;

  [[nodiscard]] const QString& ConfigDirectory() const noexcept { return configDirectory_; }
  [[nodiscard]] const QString& FilePath() const noexcept { return filePath_; }

  [[nodiscard]] static QString DefaultConfigDirectory();
  [[nodiscard]] static std::string DefaultViewerName();

 private:
  QString configDirectory_;
  QString filePath_;
};

}  // namespace matrixcode::platform
