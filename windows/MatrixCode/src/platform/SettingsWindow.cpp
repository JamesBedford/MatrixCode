#include "matrixcode/platform/SettingsWindow.h"

#include <algorithm>
#include <array>
#include <commctrl.h>
#include <cwchar>
#include <initializer_list>
#include <string>
#include <utility>
#include <vector>

#include "matrixcode/core/Settings.h"
#include "matrixcode/core/Utf8.h"
#include "matrixcode/platform/DocumentEditor.h"
#include "Version.h"
#include "resource.h"

namespace matrixcode::platform {
namespace {

constexpr wchar_t kClassName[] = L"MatrixCode.Settings.Window";
constexpr wchar_t kJsonClassName[] = L"MatrixCode.Settings.JsonWindow";
enum ControlId : int {
  IdSpeed = 1001,
  IdDensity,
  IdTrail,
  IdTrailVariation,
  IdRampUp,
  IdGlyphRate,
  IdGlyphScale,
  IdGlow,
  IdLeadBrightness,
  IdVignette,
  IdPreset,
  IdCustomColor,
  IdGlyphMode,
  IdGlyphFont,
  IdQuality,
  IdViewerName,
  IdMirror,
  IdScanlines,
  IdOverlap,
  IdSave,
  IdCancel,
  IdReset,
  IdDocuments,
  IdRawJson,
  IdJsonEdit = 2001,
  IdJsonSave,
  IdJsonCancel,
};

struct WindowState {
  SettingsStoreWin32* store = nullptr;
  SettingsSnapshot settings;
  HWND owner = nullptr;
  HWND window = nullptr;
  bool done = false;
  INT_PTR result = IDCANCEL;
  UINT dpi = 96;
  HFONT font = nullptr;
  int horizontalScrollPosition = 0;
  int verticalScrollPosition = 0;
};

struct JsonWindowState {
  SettingsSnapshot* settings = nullptr;
  HWND edit = nullptr;
  bool done = false;
  INT_PTR result = IDCANCEL;
  UINT dpi = 96;
  HFONT font = nullptr;
};

[[nodiscard]] std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(
    CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (size <= 0) return {};
  std::wstring result(static_cast<std::size_t>(size), L'\0');
  MultiByteToWideChar(
    CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
    result.data(), size);
  return result;
}

[[nodiscard]] std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
    CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
    nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(
    CP_UTF8, WC_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
    result.data(), size, nullptr, nullptr);
  return result;
}

[[nodiscard]] int Scale(const int value, const UINT dpi) noexcept {
  return MulDiv(value, static_cast<int>(dpi), 96);
}

[[nodiscard]] UINT OwnerDpi(const HWND owner) noexcept {
  return owner != nullptr ? std::max(96u, GetDpiForWindow(owner)) : std::max(96u, GetDpiForSystem());
}

[[nodiscard]] RECT MonitorWorkArea(const HWND owner) noexcept {
  MONITORINFO info{sizeof(info)};
  const HMONITOR monitor = MonitorFromWindow(
    owner, owner != nullptr ? MONITOR_DEFAULTTONEAREST : MONITOR_DEFAULTTOPRIMARY);
  if (GetMonitorInfoW(monitor, &info) != FALSE) return info.rcWork;
  return RECT{0, 0, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN)};
}

[[nodiscard]] HFONT CreateUiFont(const UINT dpi) {
  LOGFONTW font{};
  font.lfHeight = -MulDiv(9, static_cast<int>(dpi), 72);
  font.lfWeight = FW_NORMAL;
  wcscpy_s(font.lfFaceName, L"Segoe UI");
  return CreateFontIndirectW(&font);
}

void ApplyFontToChildren(const HWND window, const HFONT font) {
  for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) {
    SendMessageW(child, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
  }
}

void ReplaceUiFont(const HWND window, const UINT dpi, HFONT& font) {
  const HFONT replacement = CreateUiFont(dpi);
  if (replacement == nullptr) return;
  ApplyFontToChildren(window, replacement);
  if (font != nullptr) DeleteObject(font);
  font = replacement;
}

void RescaleChildren(const HWND window, const UINT oldDpi, const UINT newDpi) {
  if (oldDpi == 0 || oldDpi == newDpi) return;
  std::vector<HWND> children;
  for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) children.push_back(child);
  HDWP positions = BeginDeferWindowPos(static_cast<int>(children.size()));
  for (const HWND child : children) {
    RECT rectangle{};
    GetWindowRect(child, &rectangle);
    MapWindowPoints(HWND_DESKTOP, window, reinterpret_cast<POINT*>(&rectangle), 2);
    const int left = MulDiv(rectangle.left, static_cast<int>(newDpi), static_cast<int>(oldDpi));
    const int top = MulDiv(rectangle.top, static_cast<int>(newDpi), static_cast<int>(oldDpi));
    const int width = MulDiv(
      rectangle.right - rectangle.left, static_cast<int>(newDpi), static_cast<int>(oldDpi));
    const int height = MulDiv(
      rectangle.bottom - rectangle.top, static_cast<int>(newDpi), static_cast<int>(oldDpi));
    if (positions != nullptr) {
      positions = DeferWindowPos(
        positions, child, nullptr, left, top, width, height,
        SWP_NOACTIVATE | SWP_NOZORDER);
    } else {
      SetWindowPos(child, nullptr, left, top, width, height, SWP_NOACTIVATE | SWP_NOZORDER);
    }
  }
  if (positions != nullptr) EndDeferWindowPos(positions);
}

void SetMainScrollPosition(WindowState& state, int horizontal, int vertical) {
  const auto clampPosition = [window = state.window](const int bar, const int requested) {
    SCROLLINFO info{sizeof(info), SIF_RANGE | SIF_PAGE};
    GetScrollInfo(window, bar, &info);
    const int maximum = std::max(0, info.nMax - static_cast<int>(info.nPage) + 1);
    return std::clamp(requested, 0, maximum);
  };
  horizontal = clampPosition(SB_HORZ, horizontal);
  vertical = clampPosition(SB_VERT, vertical);
  if (horizontal == state.horizontalScrollPosition && vertical == state.verticalScrollPosition) return;
  const int deltaX = state.horizontalScrollPosition - horizontal;
  const int deltaY = state.verticalScrollPosition - vertical;
  state.horizontalScrollPosition = horizontal;
  state.verticalScrollPosition = vertical;
  SCROLLINFO horizontalInfo{sizeof(horizontalInfo), SIF_POS};
  horizontalInfo.nPos = horizontal;
  SetScrollInfo(state.window, SB_HORZ, &horizontalInfo, TRUE);
  SCROLLINFO verticalInfo{sizeof(verticalInfo), SIF_POS};
  verticalInfo.nPos = vertical;
  SetScrollInfo(state.window, SB_VERT, &verticalInfo, TRUE);
  ScrollWindowEx(
    state.window, deltaX, deltaY, nullptr, nullptr, nullptr, nullptr,
    SW_INVALIDATE | SW_ERASE | SW_SCROLLCHILDREN);
  UpdateWindow(state.window);
}

void UpdateMainScrollRanges(WindowState& state) {
  RECT client{};
  GetClientRect(state.window, &client);
  SCROLLINFO horizontal{sizeof(horizontal), SIF_RANGE | SIF_PAGE | SIF_POS};
  horizontal.nMin = 0;
  horizontal.nMax = std::max(0, Scale(820, state.dpi) - 1);
  horizontal.nPage = static_cast<UINT>(std::max<LONG>(0L, client.right - client.left));
  horizontal.nPos = state.horizontalScrollPosition;
  SetScrollInfo(state.window, SB_HORZ, &horizontal, TRUE);
  SCROLLINFO vertical{sizeof(vertical), SIF_RANGE | SIF_PAGE | SIF_POS};
  vertical.nMin = 0;
  vertical.nMax = std::max(0, Scale(480, state.dpi) - 1);
  vertical.nPage = static_cast<UINT>(std::max<LONG>(0L, client.bottom - client.top));
  vertical.nPos = state.verticalScrollPosition;
  SetScrollInfo(state.window, SB_VERT, &vertical, TRUE);
  SetMainScrollPosition(
    state, state.horizontalScrollPosition, state.verticalScrollPosition);
}

void EnsureFocusedChildVisible(WindowState& state) {
  const HWND focused = GetFocus();
  if (focused == nullptr || IsChild(state.window, focused) == FALSE) return;
  RECT rectangle{};
  GetWindowRect(focused, &rectangle);
  MapWindowPoints(HWND_DESKTOP, state.window, reinterpret_cast<POINT*>(&rectangle), 2);
  RECT client{};
  GetClientRect(state.window, &client);
  const int margin = Scale(8, state.dpi);
  int horizontal = state.horizontalScrollPosition;
  int vertical = state.verticalScrollPosition;
  if (rectangle.left < margin) horizontal += rectangle.left - margin;
  else if (rectangle.right > client.right - margin) {
    horizontal += rectangle.right - (client.right - margin);
  }
  if (rectangle.top < margin) vertical += rectangle.top - margin;
  else if (rectangle.bottom > client.bottom - margin) {
    vertical += rectangle.bottom - (client.bottom - margin);
  }
  SetMainScrollPosition(state, horizontal, vertical);
}

void LayoutJsonWindow(const HWND window, const JsonWindowState& state) {
  if (state.edit == nullptr) return;
  RECT client{};
  GetClientRect(window, &client);
  const int clientWidth = static_cast<int>(client.right - client.left);
  const int clientHeight = static_cast<int>(client.bottom - client.top);
  const int margin = Scale(14, state.dpi);
  const int buttonWidth = Scale(92, state.dpi);
  const int buttonHeight = Scale(30, state.dpi);
  const int gap = Scale(10, state.dpi);
  const int footerTop = std::max(margin, clientHeight - margin - buttonHeight);
  const int editHeight = std::max(Scale(80, state.dpi), footerTop - gap - margin);
  MoveWindow(state.edit, margin, margin,
    std::max(Scale(120, state.dpi), clientWidth - margin * 2), editHeight, TRUE);
  const HWND apply = GetDlgItem(window, IdJsonSave);
  const HWND cancel = GetDlgItem(window, IdJsonCancel);
  const int applyLeft = std::max(margin, clientWidth - margin - buttonWidth);
  MoveWindow(apply, applyLeft, footerTop, buttonWidth, buttonHeight, TRUE);
  MoveWindow(cancel, std::max(margin, applyLeft - gap - buttonWidth), footerTop,
    buttonWidth, buttonHeight, TRUE);
}

HWND CreateScaledChild(
    const HWND parent,
    const DWORD extendedStyle,
    const wchar_t* className,
    const wchar_t* text,
    const DWORD style,
    const int x,
    const int y,
    const int width,
    const int height,
    const int id = 0) {
  const UINT dpi = std::max(96u, GetDpiForWindow(parent));
  return CreateWindowExW(
    extendedStyle, className, text, WS_CHILD | WS_VISIBLE | style,
    Scale(x, dpi), Scale(y, dpi), Scale(width, dpi), Scale(height, dpi),
    parent, id == 0 ? nullptr : reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
    GetModuleHandleW(nullptr), nullptr);
}

void Label(HWND parent, const wchar_t* text, int x, int y, int width = 145) {
  CreateScaledChild(parent, 0, L"STATIC", text, 0, x, y + 4, width, 22);
}

HWND Track(
    HWND parent, int id, int x, int y, int minimum, int maximum, int position,
    int width = 220) {
  HWND control = CreateScaledChild(
    parent, 0, TRACKBAR_CLASSW, L"", WS_TABSTOP | TBS_AUTOTICKS,
    x, y, width, 28, id);
  SendMessageW(control, TBM_SETRANGEMIN, FALSE, minimum);
  SendMessageW(control, TBM_SETRANGEMAX, TRUE, maximum);
  SendMessageW(control, TBM_SETPOS, TRUE, position);
  return control;
}

HWND Combo(HWND parent, int id, int x, int y, int width = 220) {
  return CreateScaledChild(
    parent, 0, WC_COMBOBOXW, L"", WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL,
    x, y, width, 220, id);
}

HWND TextEdit(HWND parent, int id, int x, int y, int width, int limit, const std::string& value) {
  const auto text = Wide(value);
  HWND control = CreateScaledChild(
    parent, WS_EX_CLIENTEDGE, L"EDIT", text.c_str(), WS_TABSTOP | ES_AUTOHSCROLL,
    x, y, width, 24, id);
  SendMessageW(control, EM_SETLIMITTEXT, limit, 0);
  return control;
}

[[nodiscard]] std::string EditText(HWND window, int id, std::size_t maximum) {
  const HWND control = GetDlgItem(window, id);
  const int length = GetWindowTextLengthW(control);
  std::wstring value(static_cast<std::size_t>(length) + 1, L'\0');
  GetWindowTextW(control, value.data(), length + 1);
  value.resize(static_cast<std::size_t>(length));
  return TruncateUtf8(Utf8(value), maximum);
}

void AddComboItems(HWND combo, std::initializer_list<const wchar_t*> values, int selected) {
  for (const auto* value : values) SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(value));
  SendMessageW(combo, CB_SETCURSEL, selected, 0);
}

void Populate(HWND window, const SettingsSnapshot& settings) {
  constexpr int leftLabel = 22;
  constexpr int leftControl = 155;
  constexpr int rightLabel = 420;
  constexpr int rightControl = 555;
  Label(window, L"Fall speed", leftLabel, 24, 125);
  Track(window, IdSpeed, leftControl, 20, 10, 300, static_cast<int>(settings.controls.speed * 100));
  Label(window, L"Density", leftLabel, 62, 125);
  Track(window, IdDensity, leftControl, 58, 1, 1000, static_cast<int>(settings.controls.density * 10));
  Label(window, L"Trail length", leftLabel, 100, 125);
  Track(window, IdTrail, leftControl, 96, 1, 50, static_cast<int>(settings.controls.trailLength * 100));
  Label(window, L"Trail variation", leftLabel, 138, 125);
  Track(window, IdTrailVariation, leftControl, 134, 0, 100,
    static_cast<int>(settings.controls.trailVariation * 100));
  Label(window, L"Ramp up (ms)", leftLabel, 176, 125);
  Track(window, IdRampUp, leftControl, 172, 0, 60000,
    static_cast<int>(settings.controls.rampUpMilliseconds));
  Label(window, L"Glyph change rate", leftLabel, 214, 125);
  Track(window, IdGlyphRate, leftControl, 210, 0, 500,
    static_cast<int>(settings.controls.glyphRate * 100));
  Label(window, L"Glyph size", leftLabel, 252, 125);
  Track(window, IdGlyphScale, leftControl, 248, 5, 100,
    static_cast<int>(settings.controls.glyphScale * 10));

  Label(window, L"Glow", rightLabel, 24, 125);
  Track(window, IdGlow, rightControl, 20, 0, 250, static_cast<int>(settings.controls.glow * 100));
  Label(window, L"Lead brightness", rightLabel, 62, 125);
  Track(window, IdLeadBrightness, rightControl, 58, 0, 300,
    static_cast<int>(settings.controls.leadBrightness * 100));
  Label(window, L"Vignette", rightLabel, 100, 125);
  Track(window, IdVignette, rightControl, 96, 0, 100,
    static_cast<int>(settings.controls.vignette * 100));

  Label(window, L"Colour theme", rightLabel, 142, 125);
  HWND preset = Combo(window, IdPreset, rightControl, 138);
  constexpr std::array<const wchar_t*, 10> presets{
    L"Classic", L"Amber", L"Orange", L"Gold", L"Red", L"Pink", L"Purple", L"Blue", L"White", L"Custom"};
  const std::array<std::string, 10> keys{
    "classic", "amber", "orange", "gold", "red", "pink", "purple", "blue", "white", "custom"};
  int selectedPreset = 0;
  for (std::size_t index = 0; index < keys.size(); ++index) {
    SendMessageW(preset, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(presets[index]));
    if (settings.controls.preset == keys[index]) selectedPreset = static_cast<int>(index);
  }
  SendMessageW(preset, CB_SETCURSEL, selectedPreset, 0);

  Label(window, L"Custom colour", rightLabel, 180, 125);
  TextEdit(window, IdCustomColor, rightControl, 176, 220, 7, settings.controls.customColor);

  Label(window, L"Glyph set", rightLabel, 218, 125);
  HWND glyphMode = Combo(window, IdGlyphMode, rightControl, 214);
  AddComboItems(glyphMode,
    {L"Matrix mix", L"Katakana", L"Binary", L"Digits", L"Latin", L"Symbols"},
    static_cast<int>(settings.controls.glyphMode));

  Label(window, L"Glyph font", rightLabel, 256, 125);
  HWND glyphFont = Combo(window, IdGlyphFont, rightControl, 252);
  AddComboItems(glyphFont,
    {L"Matrix", L"Gothic", L"Mono", L"Terminal", L"Rounded", L"Mincho"},
    static_cast<int>(settings.controls.glyphFont));

  Label(window, L"Quality", rightLabel, 294, 125);
  HWND quality = Combo(window, IdQuality, rightControl, 290);
  AddComboItems(quality, {L"Low", L"Medium", L"High"},
    settings.controls.quality == QualityTier::Low ? 0 :
    settings.controls.quality == QualityTier::Medium ? 1 : 2);

  const auto checkbox = [window](const int id, const wchar_t* text, const int x, const int y, const bool checked) {
    HWND control = CreateScaledChild(
      window, 0, L"BUTTON", text, WS_TABSTOP | BS_AUTOCHECKBOX,
      x, y, 190, 24, id);
    SendMessageW(control, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
  };
  Label(window, L"Viewer name", leftLabel, 302, 125);
  TextEdit(window, IdViewerName, leftControl, 298, 220, 80, settings.viewerName);

  checkbox(IdMirror, L"Mirror rain glyphs", 22, 350, settings.controls.mirror);
  checkbox(IdScanlines, L"CRT scanlines", 214, 350, settings.controls.scanlines);
  checkbox(IdOverlap, L"High-density overlap", 406, 350, settings.controls.allowOverlap);

  CreateScaledChild(window, 0, L"STATIC",
    L"Intro, messages, image reveals, and countdown moments have structured editors.",
    0, 22, 400, 620, 24);
  CreateScaledChild(window, 0, L"BUTTON", L"Content editors...", WS_TABSTOP | BS_PUSHBUTTON,
    22, 430, 146, 30, IdDocuments);
  CreateScaledChild(window, 0, L"BUTTON", L"Raw JSON...", WS_TABSTOP | BS_PUSHBUTTON,
    176, 430, 112, 30, IdRawJson);
  CreateScaledChild(window, 0, L"BUTTON", L"Reset all", WS_TABSTOP | BS_PUSHBUTTON,
    296, 430, 92, 30, IdReset);
  std::wstring versionLabel = L"Version ";
  versionLabel += version::kSemanticVersion;
  CreateScaledChild(window, 0, L"STATIC", versionLabel.c_str(),
    SS_CENTER | SS_CENTERIMAGE | SS_NOPREFIX, 468, 430, 148, 30);
  CreateScaledChild(window, 0, L"BUTTON", L"Cancel", WS_TABSTOP | BS_PUSHBUTTON,
    628, 430, 82, 30, IdCancel);
  CreateScaledChild(window, 0, L"BUTTON", L"Save", WS_TABSTOP | BS_DEFPUSHBUTTON,
    718, 430, 82, 30, IdSave);
}

LRESULT CALLBACK JsonWindowProcedure(
    HWND window, const UINT message, const WPARAM wParam, const LPARAM lParam) {
  auto* state = reinterpret_cast<JsonWindowState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
    state = static_cast<JsonWindowState*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
  }
  switch (message) {
    case WM_CREATE: {
      state->dpi = std::max(96u, GetDpiForWindow(window));
      const auto encoded = Wide(EncodeSettingsUtf8(*state->settings, true));
      state->edit = CreateScaledChild(
        window, WS_EX_CLIENTEDGE, L"EDIT", encoded.c_str(),
        WS_TABSTOP | WS_VSCROLL | WS_HSCROLL |
          ES_MULTILINE | ES_AUTOVSCROLL | ES_AUTOHSCROLL | ES_WANTRETURN,
        14, 14, 712, 500, IdJsonEdit);
      SendMessageW(state->edit, EM_SETLIMITTEXT, 8u * 1024u * 1024u, 0);
      CreateScaledChild(window, 0, L"BUTTON", L"Cancel", WS_TABSTOP,
        530, 526, 92, 30, IdJsonCancel);
      CreateScaledChild(window, 0, L"BUTTON", L"Apply", WS_TABSTOP | BS_DEFPUSHBUTTON,
        632, 526, 92, 30, IdJsonSave);
      ReplaceUiFont(window, state->dpi, state->font);
      LayoutJsonWindow(window, *state);
      return 0;
    }
    case WM_SIZE:
      LayoutJsonWindow(window, *state);
      return 0;
    case WM_DPICHANGED: {
      const UINT nextDpi = std::max<UINT>(96u, static_cast<UINT>(HIWORD(wParam)));
      const auto* suggested = reinterpret_cast<const RECT*>(lParam);
      SetWindowPos(window, nullptr, suggested->left, suggested->top,
        suggested->right - suggested->left, suggested->bottom - suggested->top,
        SWP_NOACTIVATE | SWP_NOZORDER);
      RescaleChildren(window, state->dpi, nextDpi);
      state->dpi = nextDpi;
      ReplaceUiFont(window, state->dpi, state->font);
      LayoutJsonWindow(window, *state);
      return 0;
    }
    case WM_COMMAND:
      if (LOWORD(wParam) == IdJsonCancel) {
        DestroyWindow(window);
        return 0;
      }
      if (LOWORD(wParam) == IdJsonSave) {
        const int length = GetWindowTextLengthW(state->edit);
        std::wstring value(static_cast<std::size_t>(length) + 1, L'\0');
        GetWindowTextW(state->edit, value.data(), length + 1);
        value.resize(static_cast<std::size_t>(length));
        std::string error;
        auto decoded = DecodeSettings(Utf8(value), &error);
        if (!decoded.has_value()) {
          const auto messageText = Wide(error);
          MessageBoxW(window, messageText.c_str(), L"Invalid settings JSON", MB_OK | MB_ICONERROR);
          return 0;
        }
        *state->settings = std::move(*decoded);
        state->result = IDOK;
        DestroyWindow(window);
        return 0;
      }
      break;
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      if (state->font != nullptr) {
        DeleteObject(state->font);
        state->font = nullptr;
      }
      state->done = true;
      return 0;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

INT_PTR ShowJsonEditor(HWND owner, SettingsSnapshot& settings) {
  WNDCLASSEXW windowClass{sizeof(windowClass)};
  windowClass.lpfnWndProc = JsonWindowProcedure;
  windowClass.hInstance = GetModuleHandleW(nullptr);
  windowClass.hIcon = LoadIconW(windowClass.hInstance, MAKEINTRESOURCEW(IDI_MATRIXCODE_ICON));
  windowClass.hIconSm = windowClass.hIcon;
  windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  windowClass.lpszClassName = kJsonClassName;
  RegisterClassExW(&windowClass);
  JsonWindowState state{&settings};
  EnableWindow(owner, FALSE);
  const UINT dpi = OwnerDpi(owner);
  const RECT workArea = MonitorWorkArea(owner);
  const int width = std::min<int>(Scale(758, dpi), workArea.right - workArea.left);
  const int height = std::min<int>(Scale(610, dpi), workArea.bottom - workArea.top);
  HWND window = CreateWindowExW(
    WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, kJsonClassName,
    L"Matrix Code - Intro, messages, images, and countdown JSON",
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_VISIBLE,
    workArea.left + std::max<LONG>(0L, ((workArea.right - workArea.left) - width) / 2),
    workArea.top + std::max<LONG>(0L, ((workArea.bottom - workArea.top) - height) / 2),
    width, height, owner, nullptr, GetModuleHandleW(nullptr), &state);
  if (window == nullptr) {
    EnableWindow(owner, TRUE);
    return -1;
  }
  MSG message{};
  BOOL messageResult = TRUE;
  while (!state.done && (messageResult = GetMessageW(&message, nullptr, 0, 0)) > 0) {
    if (!IsDialogMessageW(window, &message)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
  }
  if (messageResult == 0) PostQuitMessage(static_cast<int>(message.wParam));
  EnableWindow(owner, TRUE);
  SetForegroundWindow(owner);
  return state.result;
}

void ReadControls(HWND window, SettingsSnapshot& settings) {
  const auto track = [window](const int id) {
    return static_cast<int>(SendDlgItemMessageW(window, id, TBM_GETPOS, 0, 0));
  };
  settings.controls.speed = track(IdSpeed) / 100.0;
  settings.controls.density = track(IdDensity) / 10.0;
  settings.controls.trailLength = track(IdTrail) / 100.0;
  settings.controls.trailVariation = track(IdTrailVariation) / 100.0;
  settings.controls.rampUpMilliseconds = static_cast<double>(track(IdRampUp));
  settings.controls.glyphRate = track(IdGlyphRate) / 100.0;
  settings.controls.glyphScale = track(IdGlyphScale) / 10.0;
  settings.controls.glow = track(IdGlow) / 100.0;
  settings.controls.leadBrightness = track(IdLeadBrightness) / 100.0;
  settings.controls.vignette = track(IdVignette) / 100.0;
  constexpr std::array<const char*, 10> presetKeys{
    "classic", "amber", "orange", "gold", "red", "pink", "purple", "blue", "white", "custom"};
  const auto preset = static_cast<std::size_t>(std::max<LRESULT>(0,
    SendDlgItemMessageW(window, IdPreset, CB_GETCURSEL, 0, 0)));
  settings.controls.preset = preset < presetKeys.size() ? presetKeys[preset] : "classic";
  settings.controls.customColor = EditText(window, IdCustomColor, 7);
  const auto glyphMode = static_cast<int>(SendDlgItemMessageW(
    window, IdGlyphMode, CB_GETCURSEL, 0, 0));
  settings.controls.glyphMode = glyphMode >= 0 && glyphMode <= static_cast<int>(GlyphMode::Symbols)
    ? static_cast<GlyphMode>(glyphMode) : GlyphMode::Matrix;
  const auto glyphFont = static_cast<int>(SendDlgItemMessageW(
    window, IdGlyphFont, CB_GETCURSEL, 0, 0));
  settings.controls.glyphFont = glyphFont >= 0 && glyphFont <= static_cast<int>(GlyphFont::Mincho)
    ? static_cast<GlyphFont>(glyphFont) : GlyphFont::Matrix;
  const LRESULT quality = SendDlgItemMessageW(window, IdQuality, CB_GETCURSEL, 0, 0);
  settings.controls.quality = quality == 0 ? QualityTier::Low : quality == 1 ? QualityTier::Medium : QualityTier::High;
  settings.controls.mirror = IsDlgButtonChecked(window, IdMirror) == BST_CHECKED;
  settings.controls.scanlines = IsDlgButtonChecked(window, IdScanlines) == BST_CHECKED;
  settings.controls.allowOverlap = IsDlgButtonChecked(window, IdOverlap) == BST_CHECKED;
  settings.viewerName = EditText(window, IdViewerName, 80);
  settings = SanitizeSettings(EncodeSettings(settings));
}

LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  auto* state = reinterpret_cast<WindowState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
    state = static_cast<WindowState*>(create->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
  }
  switch (message) {
    case WM_CREATE:
      state->window = window;
      state->dpi = std::max(96u, GetDpiForWindow(window));
      Populate(window, state->settings);
      ReplaceUiFont(window, state->dpi, state->font);
      ShowScrollBar(window, SB_BOTH, FALSE);
      UpdateMainScrollRanges(*state);
      return 0;
    case WM_SIZE:
      UpdateMainScrollRanges(*state);
      return 0;
    case WM_HSCROLL:
    case WM_VSCROLL: {
      if (lParam != 0) return 0;
      const int bar = message == WM_HSCROLL ? SB_HORZ : SB_VERT;
      SCROLLINFO info{sizeof(info), SIF_ALL};
      GetScrollInfo(window, bar, &info);
      int next = bar == SB_HORZ
        ? state->horizontalScrollPosition
        : state->verticalScrollPosition;
      switch (LOWORD(wParam)) {
        case SB_LINEUP: next -= Scale(24, state->dpi); break;
        case SB_LINEDOWN: next += Scale(24, state->dpi); break;
        case SB_PAGEUP: next -= static_cast<int>(info.nPage); break;
        case SB_PAGEDOWN: next += static_cast<int>(info.nPage); break;
        case SB_THUMBTRACK: next = info.nTrackPos; break;
        case SB_TOP: next = 0; break;
        case SB_BOTTOM: next = info.nMax; break;
        default: return 0;
      }
      SetMainScrollPosition(
        *state,
        bar == SB_HORZ ? next : state->horizontalScrollPosition,
        bar == SB_VERT ? next : state->verticalScrollPosition);
      return 0;
    }
    case WM_MOUSEWHEEL: {
      const int detents = GET_WHEEL_DELTA_WPARAM(wParam) / WHEEL_DELTA;
      SetMainScrollPosition(
        *state, state->horizontalScrollPosition,
        state->verticalScrollPosition - detents * Scale(72, state->dpi));
      return 0;
    }
    case WM_DPICHANGED: {
      const UINT nextDpi = std::max<UINT>(96u, static_cast<UINT>(HIWORD(wParam)));
      SetMainScrollPosition(*state, 0, 0);
      const auto* suggested = reinterpret_cast<const RECT*>(lParam);
      SetWindowPos(window, nullptr, suggested->left, suggested->top,
        suggested->right - suggested->left, suggested->bottom - suggested->top,
        SWP_NOACTIVATE | SWP_NOZORDER);
      RescaleChildren(window, state->dpi, nextDpi);
      state->dpi = nextDpi;
      ReplaceUiFont(window, state->dpi, state->font);
      UpdateMainScrollRanges(*state);
      return 0;
    }
    case WM_COMMAND:
      switch (LOWORD(wParam)) {
        case IdSave: {
          ReadControls(window, state->settings);
          std::wstring error;
          if (!state->store->Save(state->settings, &error)) {
            MessageBoxW(window, error.c_str(), L"Matrix Code", MB_OK | MB_ICONERROR);
            return 0;
          }
          state->result = IDOK;
          DestroyWindow(window);
          return 0;
        }
        case IdCancel:
          DestroyWindow(window);
          return 0;
        case IdReset:
          SetMainScrollPosition(*state, 0, 0);
          state->settings = DefaultSettings();
          for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;) {
            HWND next = GetWindow(child, GW_HWNDNEXT);
            DestroyWindow(child);
            child = next;
          }
          Populate(window, state->settings);
          ApplyFontToChildren(window, state->font);
          return 0;
        case IdDocuments:
          ReadControls(window, state->settings);
          if (DocumentEditor::ShowModal(window, state->settings) == IDOK) {
            SetMainScrollPosition(*state, 0, 0);
            for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;) {
              HWND next = GetWindow(child, GW_HWNDNEXT);
              DestroyWindow(child);
              child = next;
            }
            Populate(window, state->settings);
            ApplyFontToChildren(window, state->font);
            UpdateMainScrollRanges(*state);
          }
          return 0;
        case IdRawJson:
          ReadControls(window, state->settings);
          if (ShowJsonEditor(window, state->settings) == IDOK) {
            SetMainScrollPosition(*state, 0, 0);
            for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;) {
              HWND next = GetWindow(child, GW_HWNDNEXT);
              DestroyWindow(child);
              child = next;
            }
            Populate(window, state->settings);
            ApplyFontToChildren(window, state->font);
            UpdateMainScrollRanges(*state);
          }
          return 0;
      }
      break;
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      if (state->font != nullptr) {
        DeleteObject(state->font);
        state->font = nullptr;
      }
      state->done = true;
      return 0;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace

INT_PTR SettingsWindow::ShowModal(HWND owner, SettingsStoreWin32& store) {
  WNDCLASSEXW windowClass{sizeof(windowClass)};
  windowClass.lpfnWndProc = WindowProcedure;
  windowClass.hInstance = GetModuleHandleW(nullptr);
  windowClass.hIcon = LoadIconW(windowClass.hInstance, MAKEINTRESOURCEW(IDI_MATRIXCODE_ICON));
  windowClass.hIconSm = windowClass.hIcon;
  windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
  windowClass.lpszClassName = kClassName;
  RegisterClassExW(&windowClass);

  WindowState state;
  state.store = &store;
  state.settings = store.Load();
  state.owner = owner;
  if (owner != nullptr) EnableWindow(owner, FALSE);
  const UINT dpi = OwnerDpi(owner);
  const RECT workArea = MonitorWorkArea(owner);
  const int width = std::min<int>(Scale(840, dpi), workArea.right - workArea.left);
  const int height = std::min<int>(Scale(520, dpi), workArea.bottom - workArea.top);
  HWND window = CreateWindowExW(
    WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT,
    kClassName,
    L"Matrix Code Settings",
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_HSCROLL | WS_VSCROLL,
    workArea.left + std::max<LONG>(0L, ((workArea.right - workArea.left) - width) / 2),
    workArea.top + std::max<LONG>(0L, ((workArea.bottom - workArea.top) - height) / 2),
    width,
    height,
    owner,
    nullptr,
    GetModuleHandleW(nullptr),
    &state);
  if (window == nullptr) {
    if (owner != nullptr) EnableWindow(owner, TRUE);
    return -1;
  }
  ShowWindow(window, SW_SHOW);
  MSG message{};
  BOOL messageResult = TRUE;
  while (!state.done && (messageResult = GetMessageW(&message, nullptr, 0, 0)) > 0) {
    const HWND previousFocus = GetFocus();
    if (!IsDialogMessageW(window, &message)) {
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (GetFocus() != previousFocus) EnsureFocusedChildVisible(state);
  }
  if (messageResult == 0) PostQuitMessage(static_cast<int>(message.wParam));
  if (owner != nullptr) {
    EnableWindow(owner, TRUE);
    SetForegroundWindow(owner);
  }
  return state.result;
}

}  // namespace matrixcode::platform
