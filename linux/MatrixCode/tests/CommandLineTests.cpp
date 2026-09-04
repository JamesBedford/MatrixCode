#include "TestHarness.h"

#include "matrixcode/platform/CommandLine.h"

void RunCommandLineTests() {
  using namespace matrixcode::platform;

  const auto ordinary = ParseCommandLine({QStringLiteral("MatrixCode")});
  MX_EXPECT(ordinary.options.has_value());
  MX_EXPECT(ordinary.options->mode == LaunchMode::Application);
  MX_EXPECT(!ordinary.options->multiMonitor);
  MX_EXPECT(!ordinary.options->forceSoftware);

  const auto application = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--multi-monitor"),
    QStringLiteral("--software")});
  MX_EXPECT(application.options.has_value());
  MX_EXPECT(application.options->mode == LaunchMode::Application);
  MX_EXPECT(application.options->multiMonitor);
  MX_EXPECT(application.options->forceSoftware);

  const auto settings = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--settings")});
  MX_EXPECT(settings.options.has_value());
  MX_EXPECT(settings.options->mode == LaunchMode::Settings);

  const auto saver = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--screensaver"),
    QStringLiteral("--multi-monitor")});
  MX_EXPECT(saver.options.has_value());
  MX_EXPECT(saver.options->mode == LaunchMode::ScreenSaver);
  MX_EXPECT(saver.options->multiMonitor);

  const auto rootSaver = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("-root")});
  MX_EXPECT(rootSaver.options.has_value());
  MX_EXPECT(rootSaver.options->mode == LaunchMode::ScreenSaver);

  const auto normalizedRootSaver = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--root")});
  MX_EXPECT(normalizedRootSaver.options.has_value());
  MX_EXPECT(normalizedRootSaver.options->mode == LaunchMode::ScreenSaver);

  const auto hostedRoot = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--root")}, QStringLiteral("0x1234"));
  MX_EXPECT(hostedRoot.options.has_value());
  MX_EXPECT(hostedRoot.options->mode == LaunchMode::ScreenSaver);
  MX_EXPECT(hostedRoot.options->xscreensaverHosted);
  MX_EXPECT_EQ(hostedRoot.options->parentWindowId, quint64{0x1234});

  const auto preview = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--preview"), QStringLiteral("0x1234")});
  MX_EXPECT(preview.options.has_value());
  MX_EXPECT(preview.options->mode == LaunchMode::Preview);
  MX_EXPECT_EQ(preview.options->parentWindowId, quint64{0x1234});

  const auto windowId = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--window-id=42")});
  MX_EXPECT(windowId.options.has_value());
  MX_EXPECT(windowId.options->mode == LaunchMode::Preview);
  MX_EXPECT_EQ(windowId.options->parentWindowId, quint64{42});

  const auto xscreensaverWindowId = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("-window-id"), QStringLiteral("1234")});
  MX_EXPECT(xscreensaverWindowId.options.has_value());
  MX_EXPECT(xscreensaverWindowId.options->mode == LaunchMode::Preview);
  MX_EXPECT_EQ(xscreensaverWindowId.options->parentWindowId, quint64{1234});

  const auto xscreensaverSettingsPreview = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--root"),
    QStringLiteral("--window-id"), QStringLiteral("0x1234")}, QStringLiteral("0x1234"));
  MX_EXPECT(xscreensaverSettingsPreview.options.has_value());
  MX_EXPECT(xscreensaverSettingsPreview.options->mode == LaunchMode::Preview);
  MX_EXPECT(!xscreensaverSettingsPreview.options->xscreensaverHosted);
  MX_EXPECT_EQ(xscreensaverSettingsPreview.options->parentWindowId, quint64{0x1234});

  const auto capture = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("--capture=/tmp/matrix.png"),
    QStringLiteral("--software")});
  MX_EXPECT(capture.options.has_value());
  MX_EXPECT(capture.options->mode == LaunchMode::Capture);
  MX_EXPECT_EQ(capture.options->capturePath, QStringLiteral("/tmp/matrix.png"));
  MX_EXPECT(capture.options->forceSoftware);

  const auto help = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("-h")});
  MX_EXPECT(help.options.has_value());
  MX_EXPECT(help.options->mode == LaunchMode::Help);
  MX_EXPECT(CommandLineHelp().contains(QStringLiteral("--screensaver")));
  MX_EXPECT(CommandLineHelp().contains(QStringLiteral("-root")));
  MX_EXPECT(CommandLineHelp().contains(QStringLiteral("--root")));
  MX_EXPECT(CommandLineHelp().contains(QStringLiteral("-window-id")));

  for (const auto& invalid : {
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--unknown")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--preview")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--preview=0")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("-window-id")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("-window-id=0")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--capture=")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--settings"),
           QStringLiteral("--screensaver")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--settings"),
           QStringLiteral("--multi-monitor")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--screensaver"),
           QStringLiteral("--window-id"), QStringLiteral("42")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("-root"),
           QStringLiteral("--settings")},
         QStringList{QStringLiteral("MatrixCode"), QStringLiteral("--software"),
           QStringLiteral("--software")},
       }) {
    const auto result = ParseCommandLine(invalid);
    MX_EXPECT(!result.options.has_value());
    MX_EXPECT(!result.error.isEmpty());
  }

  const auto invalidHostedRoot = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("-root")}, QStringLiteral("not-a-window"));
  MX_EXPECT(!invalidHostedRoot.options.has_value());
  MX_EXPECT(invalidHostedRoot.error.contains(QStringLiteral("XSCREENSAVER_WINDOW")));

  const auto hostedMultiMonitor = ParseCommandLine({
    QStringLiteral("MatrixCode"), QStringLiteral("-root"),
    QStringLiteral("--multi-monitor")}, QStringLiteral("42"));
  MX_EXPECT(!hostedMultiMonitor.options.has_value());
  MX_EXPECT(!hostedMultiMonitor.error.isEmpty());
}
