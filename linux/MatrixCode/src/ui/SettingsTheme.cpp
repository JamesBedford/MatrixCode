#include "matrixcode/ui/SettingsTheme.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

namespace matrixcode::ui {
namespace {

QColor FromRgb(const std::array<float, 3>& rgb) {
  const auto channel = [](const float value) {
    return static_cast<int>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
  };
  return QColor(channel(rgb[0]), channel(rgb[1]), channel(rgb[2]));
}

/** Opaque equivalent of painting `overlay` at `amount` opacity over `base`. */
QColor Blend(const QColor& base, const QColor& overlay, const double amount) {
  const auto channel = [amount](const int from, const int to) {
    return static_cast<int>(std::lround(from + (to - from) * amount));
  };
  return QColor(
    channel(base.red(), overlay.red()),
    channel(base.green(), overlay.green()),
    channel(base.blue(), overlay.blue()));
}

/** Accent at `amount` opacity over the window, like the web's rgb(accent / amount) surfaces. */
QColor Tint(const SettingsTheme& theme, const double amount) {
  return Blend(theme.background, theme.accent, amount);
}

/** Body text at `amount` opacity over the window, for secondary text. */
QColor Fade(const SettingsTheme& theme, const double amount) {
  return Blend(theme.background, theme.text, amount);
}

QColor InputBackground(const SettingsTheme& theme) {
  return Blend(theme.background, Qt::black, 0.4);
}

constexpr double kSelectionOpacity = 0.4;
constexpr double kButtonOpacity = 0.14;
constexpr double kHintTextOpacity = 0.6;
constexpr double kDisabledTextOpacity = 0.4;

constexpr auto kStyleSheetTemplate = R"(
    QDialog { background: %window%; color: %text%; }
    QLabel#settingsTitle { color: %accent%; }
    QTabWidget::pane { border: 1px solid %frame%; background: %pane%; border-radius: 6px; }
    QTabBar::tab { background: %tab%; color: %muted%; padding: 9px 15px; border: 1px solid %frame%; }
    QTabBar::tab:selected { background: %tabSelected%; color: %label%; }
    QLabel[kind="hint"] { color: %hint%; padding: 2px 0 8px 0; }
    QGroupBox { border: 1px solid %frame%; border-radius: 6px; margin-top: 11px; padding-top: 8px; font-weight: 600; }
    QGroupBox::title { subcontrol-origin: margin; left: 10px; color: %label%; }
    QLineEdit, QComboBox, QDoubleSpinBox, QDateTimeEdit, QListWidget, QTableWidget {
      background: %input%; color: %text%; border: 1px solid %border%; border-radius: 4px; padding: 5px;
      selection-background-color: %selection%;
    }
    QPushButton, QToolButton { background: %button%; color: %text%; border: 1px solid %border%; border-radius: 4px; padding: 6px 12px; }
    QPushButton:hover, QToolButton:hover { background: %buttonHover%; border-color: %buttonHoverBorder%; }
    QPushButton:default { background: %selection%; border-color: %defaultBorder%; }
    QPushButton:disabled, QToolButton:disabled { color: %disabled%; }
    QCheckBox { spacing: 7px; }
  )";

}  // namespace

SettingsTheme SettingsThemeForPalette(const ColorPalette& palette) {
  const QColor accent = FromRgb(palette.bright);
  return {FromRgb(palette.background), accent, FromRgb(palette.head), Blend(accent, Qt::white, 0.35)};
}

QString SettingsStyleSheet(const SettingsTheme& theme) {
  const std::array<std::pair<QLatin1String, QColor>, 18> tokens{{
    {QLatin1String("%window%"), theme.background},
    {QLatin1String("%text%"), theme.text},
    {QLatin1String("%accent%"), theme.accent},
    {QLatin1String("%label%"), theme.label},
    {QLatin1String("%muted%"), Fade(theme, 0.7)},
    {QLatin1String("%hint%"), Fade(theme, kHintTextOpacity)},
    {QLatin1String("%disabled%"), Fade(theme, kDisabledTextOpacity)},
    {QLatin1String("%pane%"), Tint(theme, 0.04)},
    {QLatin1String("%tab%"), Tint(theme, 0.07)},
    {QLatin1String("%tabSelected%"), Tint(theme, 0.16)},
    {QLatin1String("%frame%"), Tint(theme, 0.25)},
    {QLatin1String("%border%"), Tint(theme, 0.35)},  // web --mx-border
    {QLatin1String("%input%"), InputBackground(theme)},
    {QLatin1String("%selection%"), Tint(theme, kSelectionOpacity)},
    {QLatin1String("%button%"), Tint(theme, kButtonOpacity)},
    {QLatin1String("%buttonHover%"), Tint(theme, 0.24)},
    {QLatin1String("%buttonHoverBorder%"), Tint(theme, 0.65)},
    {QLatin1String("%defaultBorder%"), Tint(theme, 0.85)},
  }};
  QString styleSheet = QString::fromLatin1(kStyleSheetTemplate);
  // Longer names first: %button% is a prefix of %buttonHover%, and %tab% of %tabSelected%.
  auto ordered = tokens;
  std::sort(ordered.begin(), ordered.end(), [](const auto& left, const auto& right) {
    return left.first.size() > right.first.size();
  });
  for (const auto& [token, color] : ordered) styleSheet.replace(token, color.name(QColor::HexRgb));
  return styleSheet;
}

QPalette SettingsPalette(const SettingsTheme& theme) {
  QPalette palette(Tint(theme, kButtonOpacity), theme.background);
  palette.setColor(QPalette::WindowText, theme.text);
  palette.setColor(QPalette::Base, InputBackground(theme));
  palette.setColor(QPalette::AlternateBase, Tint(theme, 0.06));
  palette.setColor(QPalette::Text, theme.text);
  palette.setColor(QPalette::ButtonText, theme.text);
  palette.setColor(QPalette::BrightText, theme.accent);
  palette.setColor(QPalette::Highlight, Tint(theme, kSelectionOpacity));
  palette.setColor(QPalette::HighlightedText, theme.text);
  palette.setColor(QPalette::PlaceholderText, Fade(theme, kHintTextOpacity));
  palette.setColor(QPalette::Link, theme.accent);
  palette.setColor(QPalette::ToolTipBase, InputBackground(theme));
  palette.setColor(QPalette::ToolTipText, theme.text);
  const QColor disabledText = Fade(theme, kDisabledTextOpacity);
  for (const auto role : {QPalette::WindowText, QPalette::Text, QPalette::ButtonText}) {
    palette.setColor(QPalette::Disabled, role, disabledText);
  }
  return palette;
}

}  // namespace matrixcode::ui
