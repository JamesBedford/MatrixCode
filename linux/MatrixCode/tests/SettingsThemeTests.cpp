#include "TestHarness.h"

#include <exception>
#include <iostream>

#include <QApplication>
#include <QComboBox>
#include <QDate>
#include <QDateTime>
#include <QLabel>
#include <QLineEdit>

#include "matrixcode/core/HolidayResolver.h"
#include "matrixcode/core/Settings.h"
#include "matrixcode/ui/SettingsDialog.h"
#include "matrixcode/ui/SettingsTheme.h"

namespace {

using namespace matrixcode;
using namespace matrixcode::ui;

Controls PresetControls(const std::string& preset, const std::string& customColor = "#00FF41") {
  Controls controls;
  controls.preset = preset;
  controls.customColor = customColor;
  return controls;
}

SettingsTheme ThemeFor(const Controls& controls) {
  return SettingsThemeForPalette(PaletteForControls(controls));
}

std::string Hex(const QColor& color) {
  return color.name(QColor::HexRgb).toStdString();
}

void RunThemeDerivationTests() {
  const SettingsTheme classic = ThemeFor(PresetControls("classic"));
  MX_EXPECT_EQ(Hex(classic.background), std::string("#0d0208"));
  MX_EXPECT_EQ(Hex(classic.accent), std::string("#00ff41"));
  MX_EXPECT_EQ(Hex(classic.text), std::string("#deffe4"));

  const SettingsTheme purple = ThemeFor(PresetControls("purple"));
  MX_EXPECT_EQ(Hex(purple.background), std::string("#08020d"));
  MX_EXPECT_EQ(Hex(purple.accent), std::string("#b23bff"));
  MX_EXPECT_EQ(Hex(purple.label), std::string("#cd80ff"));

  const SettingsTheme custom = ThemeFor(PresetControls("custom", "#FF6600"));
  MX_EXPECT_EQ(Hex(custom.background), std::string("#0d0500"));
  MX_EXPECT_EQ(Hex(custom.accent), std::string("#ff6600"));

  const QString classicSheet = SettingsStyleSheet(classic);
  const QString amberSheet = SettingsStyleSheet(ThemeFor(PresetControls("amber")));
  MX_EXPECT(!classicSheet.contains('%'));
  MX_EXPECT(!amberSheet.contains('%'));
  MX_EXPECT(classicSheet.contains("#00ff41"));
  MX_EXPECT(!classicSheet.contains("#ffb000"));
  MX_EXPECT(amberSheet.contains("#ffb000"));
  MX_EXPECT(!amberSheet.contains("#00ff41"));

  const QPalette palette = SettingsPalette(purple);
  MX_EXPECT(palette.color(QPalette::Window) == purple.background);
  MX_EXPECT(palette.color(QPalette::WindowText) == purple.text);
  MX_EXPECT(palette.color(QPalette::Text) == purple.text);
  MX_EXPECT(palette.color(QPalette::Disabled, QPalette::Text) != purple.text);

  // Holiday overrides recolour the chrome exactly as they recolour the rain.
  const Controls valentines = EffectiveControlsForLocalDate(PresetControls("purple"), 2, 14);
  MX_EXPECT_EQ(Hex(ThemeFor(valentines).accent), std::string("#ff2a2a"));
}

void RunDialogThemeTests() {
  SettingsSnapshot settings = DefaultSettings();
  settings.controls.preset = "classic";
  SettingsDialog dialog(settings);
  auto* preset = dialog.findChild<QComboBox*>("preset");
  auto* customColor = dialog.findChild<QLineEdit*>("customColor");
  MX_EXPECT(preset != nullptr);
  MX_EXPECT(customColor != nullptr);
  MX_EXPECT(dialog.styleSheet().contains("#00ff41"));
  MX_EXPECT(dialog.palette().color(QPalette::Window) == ThemeFor(PresetControls("classic")).background);

  preset->setCurrentIndex(preset->findData("red"));
  MX_EXPECT(dialog.styleSheet().contains("#ff2a2a"));
  MX_EXPECT(!dialog.styleSheet().contains("#00ff41"));
  MX_EXPECT(dialog.palette().color(QPalette::Window) == ThemeFor(PresetControls("red")).background);

  preset->setCurrentIndex(preset->findData("custom"));
  customColor->setText("#FF6600");
  MX_EXPECT(dialog.styleSheet().contains("#ff6600"));
  // A partially typed colour keeps the last valid theme instead of flashing the fallback green.
  customColor->setText("#12");
  MX_EXPECT(dialog.styleSheet().contains("#ff6600"));

  // The host resolver applies date overrides, so the chrome matches the rendered rain.
  dialog.SetThemeControlsResolver([](const Controls& controls) {
    return EffectiveControlsForLocalDate(controls, 3, 17);
  });
  MX_EXPECT(dialog.styleSheet().contains("#00ff41"));

  auto* overrideLabel = dialog.findChild<QLabel*>("colorOverride");
  MX_EXPECT(overrideLabel != nullptr);
  const QDate date = QDate::currentDate();
  const QDateTime start(date.startOfDay());
  const QDateTime end(date.addDays(1).startOfDay());
  FullMoonDayCache fullMoon;
  const auto expected = ColorOverrideLabel(
    date.month(), date.day(),
    fullMoon.ContainsFullMoon(
      static_cast<double>(start.toMSecsSinceEpoch()),
      static_cast<double>(end.toMSecsSinceEpoch())));
  if (expected) {
    MX_EXPECT(!overrideLabel->isHidden());
    MX_EXPECT_EQ(overrideLabel->text().toStdString(), std::string(*expected));
  } else {
    MX_EXPECT(overrideLabel->isHidden());
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM")) qputenv("QT_QPA_PLATFORM", "offscreen");
  QApplication application(argc, argv);
  try {
    RunThemeDerivationTests();
    RunDialogThemeTests();
    std::cout << "MatrixCodeLinuxUiTests: " << matrixcode::test::assertions
              << " assertions passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "MatrixCodeLinuxUiTests failed: " << error.what() << '\n';
    return 1;
  }
}
