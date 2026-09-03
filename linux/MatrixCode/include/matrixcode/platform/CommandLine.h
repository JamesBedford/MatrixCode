#pragma once

#include <optional>

#include <QString>
#include <QStringList>

namespace matrixcode::platform {

enum class LaunchMode {
  Application,
  Settings,
  ScreenSaver,
  Preview,
  Capture,
  Help,
};

struct CommandLineOptions {
  LaunchMode mode = LaunchMode::Application;
  bool multiMonitor = false;
  bool forceSoftware = false;
  quint64 parentWindowId = 0;
  QString capturePath;
};

struct CommandLineParseResult {
  std::optional<CommandLineOptions> options;
  QString error;
};

/** Parse QCoreApplication::arguments(), including the executable at index zero. */
[[nodiscard]] CommandLineParseResult ParseCommandLine(const QStringList& arguments);

[[nodiscard]] QString CommandLineHelp();

}  // namespace matrixcode::platform
