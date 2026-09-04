#include "matrixcode/platform/CommandLine.h"

#include <utility>

namespace matrixcode::platform {
namespace {

struct ParsedValue {
  bool matched = false;
  QString value;
};

[[nodiscard]] ParsedValue OptionValue(
    const QString& argument,
    const QString& name,
    const QStringList& arguments,
    qsizetype& index,
    QString& error) {
  if (argument == name) {
    if (index + 1 >= arguments.size()) {
      error = QStringLiteral("%1 requires a value.").arg(name);
      return {true, {}};
    }
    ++index;
    return {true, arguments[index]};
  }
  const QString prefix = name + QLatin1Char('=');
  if (argument.startsWith(prefix)) return {true, argument.sliced(prefix.size())};
  return {};
}

[[nodiscard]] bool SetMode(
    CommandLineOptions& options,
    const LaunchMode mode,
    bool& modeWasSet,
    QString& error) {
  if (modeWasSet) {
    error = QStringLiteral("Only one launch mode may be selected.");
    return false;
  }
  options.mode = mode;
  modeWasSet = true;
  return true;
}

[[nodiscard]] std::optional<quint64> ParseWindowId(const QString& value) {
  if (value.isEmpty() || value.startsWith(QLatin1Char('-'))) return std::nullopt;
  bool valid = false;
  const quint64 parsed = value.toULongLong(&valid, 0);
  return valid && parsed != 0 ? std::optional<quint64>(parsed) : std::nullopt;
}

}  // namespace

CommandLineParseResult ParseCommandLine(
    const QStringList& arguments,
    const QString& xscreensaverWindow) {
  CommandLineOptions options;
  bool modeWasSet = false;
  const qsizetype firstArgument = arguments.isEmpty() ? 0 : 1;
  bool previewRequested = false;
  for (qsizetype index = firstArgument; index < arguments.size(); ++index) {
    const QString& argument = arguments[index];
    previewRequested = previewRequested ||
      argument == QStringLiteral("--preview") ||
      argument.startsWith(QStringLiteral("--preview=")) ||
      argument == QStringLiteral("--window-id") ||
      argument.startsWith(QStringLiteral("--window-id=")) ||
      argument == QStringLiteral("-window-id") ||
      argument.startsWith(QStringLiteral("-window-id="));
  }
  for (qsizetype index = firstArgument; index < arguments.size(); ++index) {
    const QString argument = arguments[index];
    if (argument == QStringLiteral("--multi-monitor")) {
      if (options.multiMonitor) return {std::nullopt, QStringLiteral("--multi-monitor was specified more than once.")};
      options.multiMonitor = true;
      continue;
    }
    if (argument == QStringLiteral("--software")) {
      if (options.forceSoftware) return {std::nullopt, QStringLiteral("--software was specified more than once.")};
      options.forceSoftware = true;
      continue;
    }
    if (argument == QStringLiteral("--settings")) {
      QString modeError;
      if (!SetMode(options, LaunchMode::Settings, modeWasSet, modeError)) {
        return {std::nullopt, std::move(modeError)};
      }
      continue;
    }
    const bool rootAlias = argument == QStringLiteral("-root") ||
      argument == QStringLiteral("--root");
    if (rootAlias && previewRequested) continue;
    if (argument == QStringLiteral("--screensaver") || rootAlias) {
      std::optional<quint64> hostWindow;
      if (rootAlias && !xscreensaverWindow.isEmpty()) {
        hostWindow = ParseWindowId(xscreensaverWindow);
        if (!hostWindow.has_value()) {
          return {std::nullopt,
            QStringLiteral("XSCREENSAVER_WINDOW must be a non-zero decimal or hexadecimal integer.")};
        }
      }
      QString modeError;
      if (!SetMode(options, LaunchMode::ScreenSaver, modeWasSet, modeError)) {
        return {std::nullopt, std::move(modeError)};
      }
      if (hostWindow.has_value()) {
        options.xscreensaverHosted = true;
        options.parentWindowId = *hostWindow;
      }
      continue;
    }
    if (argument == QStringLiteral("--help") || argument == QStringLiteral("-h")) {
      QString modeError;
      if (!SetMode(options, LaunchMode::Help, modeWasSet, modeError)) {
        return {std::nullopt, std::move(modeError)};
      }
      continue;
    }

    QString valueError;
    ParsedValue value = OptionValue(
      argument, QStringLiteral("--preview"), arguments, index, valueError);
    if (!value.matched) {
      value = OptionValue(
        argument, QStringLiteral("--window-id"), arguments, index, valueError);
    }
    if (!value.matched) {
      value = OptionValue(
        argument, QStringLiteral("-window-id"), arguments, index, valueError);
    }
    if (value.matched) {
      if (!valueError.isEmpty()) return {std::nullopt, std::move(valueError)};
      const auto windowId = ParseWindowId(value.value);
      if (!windowId.has_value()) {
        return {std::nullopt, QStringLiteral("The preview window id must be a non-zero decimal or hexadecimal integer.")};
      }
      QString modeError;
      if (!SetMode(options, LaunchMode::Preview, modeWasSet, modeError)) {
        return {std::nullopt, std::move(modeError)};
      }
      options.parentWindowId = *windowId;
      continue;
    }

    value = OptionValue(
      argument, QStringLiteral("--capture"), arguments, index, valueError);
    if (value.matched) {
      if (!valueError.isEmpty()) return {std::nullopt, std::move(valueError)};
      if (value.value.isEmpty()) {
        return {std::nullopt, QStringLiteral("--capture requires a non-empty output path.")};
      }
      QString modeError;
      if (!SetMode(options, LaunchMode::Capture, modeWasSet, modeError)) {
        return {std::nullopt, std::move(modeError)};
      }
      options.capturePath = value.value;
      continue;
    }
    return {std::nullopt, QStringLiteral("Unknown option: %1").arg(argument)};
  }

  if (options.multiMonitor &&
      options.mode != LaunchMode::Application && options.mode != LaunchMode::ScreenSaver) {
    return {std::nullopt, QStringLiteral("--multi-monitor is only valid for application or screen-saver playback.")};
  }
  if (options.multiMonitor && options.xscreensaverHosted) {
    return {std::nullopt,
      QStringLiteral("--multi-monitor cannot be combined with an XScreenSaver host window.")};
  }
  return {std::move(options), {}};
}

QString CommandLineHelp() {
  return QStringLiteral(
    "Usage: MatrixCode [MODE] [OPTIONS]\n"
    "\n"
    "Modes:\n"
    "  --settings                 Open settings without starting playback\n"
    "  --screensaver, -root, --root\n"
    "                             Run full-screen screen-saver playback\n"
    "  --preview ID               Render into an X11 preview window\n"
    "  --window-id ID             Alias for --preview ID\n"
    "  -window-id ID              XScreenSaver alias for --preview ID\n"
    "  --capture PATH             Write a deterministic frame capture\n"
    "  -h, --help                 Show this help\n"
    "\n"
    "Options:\n"
    "  --multi-monitor            Present one continuous grid on every display\n"
    "  --software                 Force the software graphics implementation\n");
}

}  // namespace matrixcode::platform
