#include "matrixcode/platform/SettingsChrome.h"

#include <algorithm>
#include <cmath>

#include <uxtheme.h>

namespace matrixcode::platform {
namespace {

[[nodiscard]] BYTE Channel(const float value) noexcept {
  return static_cast<BYTE>(std::lround(std::clamp(value, 0.0f, 1.0f) * 255.0f));
}

[[nodiscard]] COLORREF ToColorRef(const std::array<float, 3>& rgb) noexcept {
  return RGB(Channel(rgb[0]), Channel(rgb[1]), Channel(rgb[2]));
}

[[nodiscard]] COLORREF Blend(const COLORREF base, const COLORREF overlay, const double amount) noexcept {
  const auto channel = [amount](const int from, const int to) {
    return static_cast<BYTE>(std::lround(from + (to - from) * amount));
  };
  return RGB(
    channel(GetRValue(base), GetRValue(overlay)),
    channel(GetGValue(base), GetGValue(overlay)),
    channel(GetBValue(base), GetBValue(overlay)));
}

void ReplaceBrush(HBRUSH& brush, const COLORREF color) {
  if (brush != nullptr) DeleteObject(brush);
  brush = CreateSolidBrush(color);
}

BOOL CALLBACK StripChildVisualStyle(HWND child, LPARAM) {
  SetWindowTheme(child, L"", L"");
  return TRUE;
}

}  // namespace

bool SettingsChrome::Apply(const ColorPalette& next) {
  if (windowBrush != nullptr && palette.background == next.background &&
      palette.head == next.head && palette.bright == next.bright) {
    return false;
  }
  palette = next;
  background = ToColorRef(palette.background);
  text = ToColorRef(palette.head);
  accent = ToColorRef(palette.bright);
  input = Blend(background, RGB(0, 0, 0), 0.4);
  button = Blend(background, accent, 0.14);
  ReplaceBrush(windowBrush, background);
  ReplaceBrush(inputBrush, input);
  ReplaceBrush(buttonBrush, button);
  return true;
}

void SettingsChrome::Clear() noexcept {
  if (windowBrush != nullptr) DeleteObject(windowBrush);
  if (inputBrush != nullptr) DeleteObject(inputBrush);
  if (buttonBrush != nullptr) DeleteObject(buttonBrush);
  windowBrush = inputBrush = buttonBrush = nullptr;
}

bool SettingsChrome::HandleColor(const UINT message, const WPARAM wParam, LRESULT& result) const {
  if (windowBrush == nullptr) return false;
  const HDC device = reinterpret_cast<HDC>(wParam);
  SetTextColor(device, text);
  switch (message) {
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX:
      SetBkColor(device, input);
      result = reinterpret_cast<LRESULT>(inputBrush);
      return true;
    case WM_CTLCOLORBTN:
      SetBkColor(device, button);
      result = reinterpret_cast<LRESULT>(buttonBrush);
      return true;
    case WM_CTLCOLORSTATIC:
      SetBkColor(device, background);
      result = reinterpret_cast<LRESULT>(windowBrush);
      return true;
    default:
      return false;
  }
}

void StripSettingsVisualStyles(const HWND parent) {
  EnumChildWindows(parent, StripChildVisualStyle, 0);
}

}  // namespace matrixcode::platform
