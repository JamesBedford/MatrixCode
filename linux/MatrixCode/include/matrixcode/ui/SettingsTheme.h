#pragma once

#include <QColor>
#include <QPalette>
#include <QString>

#include "matrixcode/core/Types.h"

namespace matrixcode::ui {

/**
 * Settings-window colours derived from the rain palette. This is the Qt
 * counterpart of the web `--mx-*` chrome tokens and macOS
 * MatrixCodeSettingsTheme, so the dialog follows the active colour theme.
 */
struct SettingsTheme {
  QColor background;  // Rain palette background stop: the window surface.
  QColor accent;      // Rain palette bright stop (web --mx-green): title and focus.
  QColor text;        // Rain palette head stop: body, input, and button text.
  QColor label;       // Accent lifted 35% toward white (web --mx-label): headings.
};

[[nodiscard]] SettingsTheme SettingsThemeForPalette(const ColorPalette& palette);
[[nodiscard]] QString SettingsStyleSheet(const SettingsTheme& theme);
/** Palette for the widget parts a style sheet leaves to the style: labels, check boxes, and popups. */
[[nodiscard]] QPalette SettingsPalette(const SettingsTheme& theme);

}  // namespace matrixcode::ui
