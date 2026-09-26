#pragma once

#include <windows.h>

#include "matrixcode/core/Types.h"

namespace matrixcode::platform {

/**
 * Settings-window brushes for one rain palette. Surfaces use the palette
 * background; text uses the head stop and buttons a 14% accent tint, matching
 * the Linux settings theme and the web --mx-bg / --mx-panel tokens.
 */
struct SettingsChrome {
  ColorPalette palette{};
  COLORREF background = 0;
  COLORREF text = 0;
  COLORREF accent = 0;
  COLORREF input = 0;
  COLORREF button = 0;
  HBRUSH windowBrush = nullptr;
  HBRUSH inputBrush = nullptr;
  HBRUSH buttonBrush = nullptr;

  /** Returns true when the brushes changed and the window should repaint. */
  [[nodiscard]] bool Apply(const ColorPalette& next);
  void Clear() noexcept;
  /** Paints a themed control color message. Returns false when this message is unrelated. */
  [[nodiscard]] bool HandleColor(UINT message, WPARAM wParam, LRESULT& result) const;
};

/** Drops the Windows visual style so button and edit colors come from HandleColor. */
void StripSettingsVisualStyles(HWND parent);

}  // namespace matrixcode::platform
