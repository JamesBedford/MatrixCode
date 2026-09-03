#include "TestHarness.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>

#include "matrixcode/platform/SettingsStoreLinux.h"

void RunSettingsStoreLinuxTests() {
  using namespace matrixcode;
  using namespace matrixcode::platform;

  QTemporaryDir temporary;
  MX_EXPECT(temporary.isValid());
  const QString directory = QDir(temporary.path()).filePath(QStringLiteral("nested/config"));
  const SettingsStoreLinux store(directory);
  MX_EXPECT_EQ(store.ConfigDirectory(), QDir::cleanPath(directory));
  MX_EXPECT(store.FilePath().endsWith(QStringLiteral("settings.json")));

  QString diagnostic = QStringLiteral("stale");
  const SettingsSnapshot defaults = store.Load(&diagnostic);
  MX_EXPECT(diagnostic.isEmpty());
  MX_EXPECT_EQ(defaults.controls.density, 2.0);
  MX_EXPECT(!defaults.viewerName.empty());

  SettingsSnapshot settings = defaults;
  settings.controls.density = 37.25;
  settings.controls.preset = "purple";
  settings.viewerName = "Trinity";
  settings.messages.enabled = true;
  settings.images.enabled = true;
  MX_EXPECT(store.Save(settings, &diagnostic));
  MX_EXPECT(diagnostic.isEmpty());
  MX_EXPECT(QFileInfo::exists(store.FilePath()));

  const SettingsSnapshot loaded = store.Load(&diagnostic);
  MX_EXPECT(diagnostic.isEmpty());
  MX_EXPECT_EQ(loaded.controls.density, 37.25);
  MX_EXPECT_EQ(loaded.controls.preset, std::string("purple"));
  MX_EXPECT_EQ(loaded.viewerName, std::string("Trinity"));
  MX_EXPECT(loaded.messages.enabled);
  MX_EXPECT(loaded.images.enabled);

  const auto permissions = QFileInfo(store.FilePath()).permissions();
  MX_EXPECT((permissions & (QFileDevice::ReadGroup | QFileDevice::WriteGroup |
    QFileDevice::ReadOther | QFileDevice::WriteOther)) == 0);

  QFile invalid(store.FilePath());
  MX_EXPECT(invalid.open(QIODevice::WriteOnly | QIODevice::Truncate));
  MX_EXPECT_EQ(invalid.write("{not-json"), qint64{9});
  invalid.close();
  const SettingsSnapshot invalidFallback = store.Load(&diagnostic);
  MX_EXPECT(!diagnostic.isEmpty());
  MX_EXPECT_EQ(invalidFallback.controls.density, 2.0);
  MX_EXPECT(!invalidFallback.viewerName.empty());

  QFile oversized(store.FilePath());
  MX_EXPECT(oversized.open(QIODevice::WriteOnly | QIODevice::Truncate));
  MX_EXPECT(oversized.resize(8 * 1024 * 1024 + 1));
  oversized.close();
  const SettingsSnapshot oversizedFallback = store.Load(&diagnostic);
  MX_EXPECT(!diagnostic.isEmpty());
  MX_EXPECT_EQ(oversizedFallback.controls.density, 2.0);

  const QByteArray previousXdg = qgetenv("XDG_CONFIG_HOME");
  qputenv("XDG_CONFIG_HOME", temporary.path().toUtf8());
  MX_EXPECT_EQ(
    SettingsStoreLinux::DefaultConfigDirectory(),
    QDir(temporary.path()).filePath(QStringLiteral("MatrixCode")));
  if (previousXdg.isNull()) qunsetenv("XDG_CONFIG_HOME");
  else qputenv("XDG_CONFIG_HOME", previousXdg);

  MX_EXPECT(!SettingsStoreLinux::DefaultViewerName().empty());
}
