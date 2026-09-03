#include "matrixcode/platform/SettingsStoreLinux.h"

#include <algorithm>
#include <string_view>
#include <utility>
#include <vector>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLockFile>
#include <QSaveFile>

#include <pwd.h>
#include <sys/types.h>
#include <unistd.h>

#include "matrixcode/core/Settings.h"
#include "matrixcode/core/Utf8.h"

namespace matrixcode::platform {
namespace {

constexpr qint64 kMaximumSettingsBytes = 8 * 1024 * 1024;
constexpr int kSettingsLockTimeoutMilliseconds = 2000;

[[nodiscard]] bool EnsureDirectory(const QString& path, QString* diagnostic) {
  if (QDir().mkpath(path)) return true;
  if (diagnostic != nullptr) {
    *diagnostic = QStringLiteral("Could not create the settings directory: %1").arg(path);
  }
  return false;
}

[[nodiscard]] bool AcquireLock(QLockFile& lock, QString* diagnostic) {
  lock.setStaleLockTime(30'000);
  if (lock.tryLock(kSettingsLockTimeoutMilliseconds)) return true;
  if (diagnostic != nullptr) {
    *diagnostic = QStringLiteral("Timed out waiting for the settings lock: %1")
      .arg(lock.error() == QLockFile::PermissionError
        ? QStringLiteral("permission denied")
        : QStringLiteral("another process is writing settings"));
  }
  return false;
}

[[nodiscard]] QString LoginName() {
  long requestedSize = ::sysconf(_SC_GETPW_R_SIZE_MAX);
  if (requestedSize < 0) requestedSize = 4096;
  const std::size_t bufferSize = static_cast<std::size_t>(
    std::clamp<long>(requestedSize, 1024, 1024 * 1024));
  std::vector<char> buffer(bufferSize);
  passwd entry{};
  passwd* result = nullptr;
  if (::getpwuid_r(::geteuid(), &entry, buffer.data(), buffer.size(), &result) == 0 &&
      result != nullptr && result->pw_name != nullptr) {
    return QString::fromUtf8(result->pw_name).trimmed();
  }
  for (const char* variable : {"USER", "LOGNAME"}) {
    const QString value = qEnvironmentVariable(variable).trimmed();
    if (!value.isEmpty()) return value;
  }
  return QFileInfo(QDir::homePath()).fileName().trimmed();
}

}  // namespace

SettingsStoreLinux::SettingsStoreLinux(QString configDirectory)
    : configDirectory_(configDirectory.isEmpty()
        ? DefaultConfigDirectory()
        : QDir::cleanPath(std::move(configDirectory))),
      filePath_(QDir(configDirectory_).filePath(QStringLiteral("settings.json"))) {}

SettingsSnapshot SettingsStoreLinux::Load(QString* diagnostic) const {
  if (diagnostic != nullptr) diagnostic->clear();
  SettingsSnapshot fallback = DefaultSettings();
  fallback.viewerName = DefaultViewerName();
  if (!EnsureDirectory(configDirectory_, diagnostic)) return fallback;

  QLockFile lock(filePath_ + QStringLiteral(".lock"));
  if (!AcquireLock(lock, diagnostic)) return fallback;
  const QFileInfo fileInfo(filePath_);
  if (!fileInfo.exists()) return fallback;
  if (!fileInfo.isFile() || fileInfo.size() < 0 || fileInfo.size() > kMaximumSettingsBytes) {
    if (diagnostic != nullptr) {
      *diagnostic = QStringLiteral("The settings file is unreadable or exceeds 8 MiB.");
    }
    return fallback;
  }

  QFile file(filePath_);
  if (!file.open(QIODevice::ReadOnly)) {
    if (diagnostic != nullptr) *diagnostic = file.errorString();
    return fallback;
  }
  const QByteArray encoded = file.read(kMaximumSettingsBytes + 1);
  if (encoded.size() > kMaximumSettingsBytes) {
    if (diagnostic != nullptr) *diagnostic = QStringLiteral("The settings file exceeds 8 MiB.");
    return fallback;
  }
  std::string parseError;
  auto decoded = DecodeSettings(
    std::string_view(encoded.constData(), static_cast<std::size_t>(encoded.size())),
    &parseError);
  if (!decoded.has_value()) {
    if (diagnostic != nullptr) {
      *diagnostic = QStringLiteral("Invalid settings JSON; defaults were loaded: %1")
        .arg(QString::fromStdString(parseError));
    }
    return fallback;
  }
  if (decoded->viewerName.empty()) decoded->viewerName = fallback.viewerName;
  return *decoded;
}

bool SettingsStoreLinux::Save(
    const SettingsSnapshot& settings,
    QString* diagnostic) const {
  if (diagnostic != nullptr) diagnostic->clear();
  if (!EnsureDirectory(configDirectory_, diagnostic)) return false;
  QLockFile lock(filePath_ + QStringLiteral(".lock"));
  if (!AcquireLock(lock, diagnostic)) return false;

  const std::string encoded = EncodeSettingsUtf8(settings, true);
  if (encoded.size() > static_cast<std::size_t>(kMaximumSettingsBytes)) {
    if (diagnostic != nullptr) *diagnostic = QStringLiteral("Encoded settings exceed 8 MiB.");
    return false;
  }
  QSaveFile file(filePath_);
  file.setDirectWriteFallback(false);
  if (!file.open(QIODevice::WriteOnly)) {
    if (diagnostic != nullptr) *diagnostic = file.errorString();
    return false;
  }
  file.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
  const qint64 written = file.write(encoded.data(), static_cast<qint64>(encoded.size()));
  if (written != static_cast<qint64>(encoded.size())) {
    if (diagnostic != nullptr) *diagnostic = file.errorString();
    file.cancelWriting();
    return false;
  }
  if (!file.commit()) {
    if (diagnostic != nullptr) *diagnostic = file.errorString();
    return false;
  }
  return true;
}

QString SettingsStoreLinux::DefaultConfigDirectory() {
  const QString configured = qEnvironmentVariable("XDG_CONFIG_HOME");
  const QString root = !configured.isEmpty() && QDir::isAbsolutePath(configured)
    ? QDir::cleanPath(configured)
    : QDir(QDir::homePath()).filePath(QStringLiteral(".config"));
  return QDir(root).filePath(QStringLiteral("MatrixCode"));
}

std::string SettingsStoreLinux::DefaultViewerName() {
  QString name = LoginName();
  if (name.isEmpty()) return "Neo";
  const QString firstScalar = name.front().isHighSurrogate() && name.size() > 1 &&
      name[1].isLowSurrogate()
    ? name.left(2)
    : name.left(1);
  name.replace(0, firstScalar.size(), firstScalar.toUpper());
  const QByteArray utf8 = name.toUtf8();
  const std::string truncated = TruncateUtf8(
    std::string_view(utf8.constData(), static_cast<std::size_t>(utf8.size())), 80);
  return truncated.empty() ? "Neo" : truncated;
}

}  // namespace matrixcode::platform
