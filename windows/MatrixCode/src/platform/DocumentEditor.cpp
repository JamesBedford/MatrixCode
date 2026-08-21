#include "matrixcode/platform/DocumentEditor.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <commctrl.h>
#include <cwchar>
#include <initializer_list>
#include <limits>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "matrixcode/core/Settings.h"
#include "matrixcode/core/IntroTimeline.h"
#include "matrixcode/core/TokenResolver.h"
#include "matrixcode/core/Utf8.h"
#include "matrixcode/platform/ImageImportWin32.h"
#include "resource.h"

namespace matrixcode::platform {
namespace {

constexpr wchar_t kClassName[] = L"MatrixCode.Documents.Window";
constexpr std::size_t kMaximumLines = 12;
constexpr std::size_t kMaximumMessages = 12;
constexpr std::size_t kMaximumImages = 64;
constexpr std::size_t kMaximumMoments = 12;
constexpr UINT_PTR kPreviewTimer = 1u;

enum ControlId : int {
  IdTab = 3001,
  IdList,
  IdAdd,
  IdRemove,
  IdUp,
  IdDown,
  IdEnabled,
  IdCheck2,
  IdCheck3,
  IdField1,
  IdField2,
  IdField3,
  IdField4,
  IdField5,
  IdField6,
  IdText,
  IdName,
  IdCombo1,
  IdCombo2,
  IdDefaultDate,
  IdDefaultTime,
  IdItemDate,
  IdItemTime,
  IdMaxVisibility,
  IdPreview,
  IdPreviewText,
  IdLivePreview,
  IdResetSection,
  IdCancel,
  IdSave,
};

using Page = DocumentPage;

struct EditorState {
  SettingsSnapshot* destination = nullptr;
  SettingsSnapshot draft;
  HWND owner = nullptr;
  HWND window = nullptr;
  HWND tab = nullptr;
  std::vector<HWND> pageControls;
  Page page = Page::Intro;
  int selected = 0;
  bool updating = false;
  bool defaultDateRepresentable = true;
  bool defaultDateDirty = false;
  bool selectedDateRepresentable = true;
  bool selectedDateDirty = false;
  bool done = false;
  INT_PTR result = IDCANCEL;
  UINT dpi = 96;
  HFONT font = nullptr;
  int horizontalScrollPosition = 0;
  int scrollPosition = 0;
  bool introPreviewRunning = false;
  ULONGLONG introPreviewStartedTicks = 0;
  double introPreviewRunStartMilliseconds = 0.0;
  double introPreviewOpacity = 1.0;
  HBRUSH previewBackground = nullptr;
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

void ApplyFont(const HWND control, const HFONT font) {
  SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
}

void ApplyFontToChildren(const HWND window, const HFONT font) {
  for (HWND child = GetWindow(window, GW_CHILD); child != nullptr;
       child = GetWindow(child, GW_HWNDNEXT)) ApplyFont(child, font);
}

void ReplaceUiFont(EditorState& state, const UINT dpi) {
  const HFONT replacement = CreateUiFont(dpi);
  if (replacement == nullptr) return;
  ApplyFontToChildren(state.window, replacement);
  if (state.font != nullptr) DeleteObject(state.font);
  state.font = replacement;
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

void SetScrollPosition(EditorState& state, int horizontal, int vertical) {
  const auto clampPosition = [window = state.window](const int bar, const int requested) {
    SCROLLINFO info{sizeof(info), SIF_RANGE | SIF_PAGE};
    GetScrollInfo(window, bar, &info);
    const int maximum = std::max(0, info.nMax - static_cast<int>(info.nPage) + 1);
    return std::clamp(requested, 0, maximum);
  };
  horizontal = clampPosition(SB_HORZ, horizontal);
  vertical = clampPosition(SB_VERT, vertical);
  if (horizontal == state.horizontalScrollPosition && vertical == state.scrollPosition) return;
  const int deltaX = state.horizontalScrollPosition - horizontal;
  const int deltaY = state.scrollPosition - vertical;
  state.horizontalScrollPosition = horizontal;
  state.scrollPosition = vertical;
  SCROLLINFO horizontalUpdate{sizeof(horizontalUpdate), SIF_POS};
  horizontalUpdate.nPos = state.horizontalScrollPosition;
  SetScrollInfo(state.window, SB_HORZ, &horizontalUpdate, TRUE);
  SCROLLINFO verticalUpdate{sizeof(verticalUpdate), SIF_POS};
  verticalUpdate.nPos = state.scrollPosition;
  SetScrollInfo(state.window, SB_VERT, &verticalUpdate, TRUE);
  ScrollWindowEx(
    state.window, deltaX, deltaY, nullptr, nullptr, nullptr, nullptr,
    SW_INVALIDATE | SW_ERASE | SW_SCROLLCHILDREN);
  UpdateWindow(state.window);
}

void UpdateScrollRange(EditorState& state) {
  RECT client{};
  GetClientRect(state.window, &client);
  SCROLLINFO horizontal{sizeof(horizontal), SIF_RANGE | SIF_PAGE | SIF_POS};
  horizontal.nMin = 0;
  horizontal.nMax = std::max(0, Scale(804, state.dpi) - 1);
  horizontal.nPage = static_cast<UINT>(std::max<LONG>(0L, client.right - client.left));
  horizontal.nPos = state.horizontalScrollPosition;
  SetScrollInfo(state.window, SB_HORZ, &horizontal, TRUE);
  SCROLLINFO vertical{sizeof(vertical), SIF_RANGE | SIF_PAGE | SIF_POS};
  vertical.nMin = 0;
  vertical.nMax = std::max(0, Scale(560, state.dpi) - 1);
  vertical.nPage = static_cast<UINT>(std::max<LONG>(0L, client.bottom - client.top));
  vertical.nPos = state.scrollPosition;
  SetScrollInfo(state.window, SB_VERT, &vertical, TRUE);
  SetScrollPosition(state, state.horizontalScrollPosition, state.scrollPosition);
}

void EnsureFocusedChildVisible(EditorState& state) {
  const HWND focused = GetFocus();
  if (focused == nullptr || IsChild(state.window, focused) == FALSE) return;
  RECT rectangle{};
  GetWindowRect(focused, &rectangle);
  MapWindowPoints(HWND_DESKTOP, state.window, reinterpret_cast<POINT*>(&rectangle), 2);
  RECT client{};
  GetClientRect(state.window, &client);
  const int margin = Scale(8, state.dpi);
  int horizontal = state.horizontalScrollPosition;
  int vertical = state.scrollPosition;
  if (rectangle.left < margin) horizontal += rectangle.left - margin;
  else if (rectangle.right > client.right - margin) {
    horizontal += rectangle.right - (client.right - margin);
  }
  if (rectangle.top < margin) vertical += rectangle.top - margin;
  else if (rectangle.bottom > client.bottom - margin) {
    vertical += rectangle.bottom - (client.bottom - margin);
  }
  SetScrollPosition(state, horizontal, vertical);
}

HWND AddControl(
    EditorState& state,
    const DWORD extendedStyle,
    const wchar_t* className,
    const wchar_t* text,
    const DWORD style,
    const int x,
    const int y,
    const int width,
    const int height,
    const int id = 0) {
  HWND control = CreateWindowExW(
    extendedStyle, className, text, WS_CHILD | WS_VISIBLE | style,
    Scale(x, state.dpi) - state.horizontalScrollPosition,
    Scale(y, state.dpi) - state.scrollPosition,
    Scale(width, state.dpi), Scale(height, state.dpi), state.window,
    id == 0 ? nullptr : reinterpret_cast<HMENU>(static_cast<INT_PTR>(id)),
    GetModuleHandleW(nullptr), nullptr);
  if (control != nullptr) {
    ApplyFont(control, state.font);
    state.pageControls.push_back(control);
  }
  return control;
}

void Label(EditorState& state, const wchar_t* text, const int x, const int y, const int width = 180) {
  AddControl(state, 0, L"STATIC", text, 0, x, y + 3, width, 21);
}

HWND Edit(
    EditorState& state,
    const int id,
    const int x,
    const int y,
    const int width,
    const int limit,
    const bool multiline = false) {
  const DWORD style = WS_TABSTOP | ES_AUTOHSCROLL |
    (multiline ? ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN | WS_VSCROLL : 0);
  HWND control = AddControl(
    state, WS_EX_CLIENTEDGE, L"EDIT", L"", style, x, y, width,
    multiline ? 72 : 24, id);
  SendMessageW(control, EM_SETLIMITTEXT, limit, 0);
  return control;
}

HWND Check(
    EditorState& state,
    const int id,
    const wchar_t* text,
    const int x,
    const int y,
    const int width = 210) {
  return AddControl(
    state, 0, L"BUTTON", text, WS_TABSTOP | BS_AUTOCHECKBOX,
    x, y, width, 24, id);
}

HWND Combo(EditorState& state, const int id, const int x, const int y, const int width = 210) {
  return AddControl(
    state, 0, WC_COMBOBOXW, L"", WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL,
    x, y, width, 240, id);
}

void AddComboItems(const HWND combo, const std::initializer_list<const wchar_t*> items, const int selected) {
  for (const auto* item : items) {
    SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(item));
  }
  SendMessageW(combo, CB_SETCURSEL, selected, 0);
}

void SetText(const HWND control, const std::string& value) {
  const auto text = Wide(value);
  SetWindowTextW(control, text.c_str());
}

void SetNumber(const HWND control, const double value, const int decimals = 0) {
  std::array<wchar_t, 64> buffer{};
  if (decimals == 0) swprintf_s(buffer.data(), buffer.size(), L"%.0f", value);
  else swprintf_s(buffer.data(), buffer.size(), L"%.*f", decimals, value);
  SetWindowTextW(control, buffer.data());
}

[[nodiscard]] std::wstring WindowText(const HWND control) {
  if (control == nullptr) return {};
  const int length = GetWindowTextLengthW(control);
  std::wstring text(static_cast<std::size_t>(length) + 1, L'\0');
  GetWindowTextW(control, text.data(), length + 1);
  text.resize(static_cast<std::size_t>(length));
  return text;
}

[[nodiscard]] std::string TextValue(const HWND control, const std::size_t maximum) {
  return TruncateUtf8(Utf8(WindowText(control)), maximum);
}

[[nodiscard]] double NumberValue(
    const HWND control,
    const double fallback,
    const double minimum,
    const double maximum) {
  const auto text = WindowText(control);
  if (text.empty()) return fallback;
  wchar_t* end = nullptr;
  const double parsed = std::wcstod(text.c_str(), &end);
  if (end == text.c_str() || !std::isfinite(parsed)) return fallback;
  return std::clamp(parsed, minimum, maximum);
}

void SetChecked(const HWND control, const bool checked) {
  SendMessageW(control, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
}

[[nodiscard]] bool Checked(const HWND window, const int id) {
  return IsDlgButtonChecked(window, id) == BST_CHECKED;
}

[[nodiscard]] std::optional<double> DateTimeValue(
    const HWND window,
    const int dateId,
    const int timeId) {
  SYSTEMTIME date{};
  if (SendDlgItemMessageW(window, dateId, DTM_GETSYSTEMTIME, 0,
      reinterpret_cast<LPARAM>(&date)) != GDT_VALID) return std::nullopt;
  SYSTEMTIME time{};
  if (SendDlgItemMessageW(window, timeId, DTM_GETSYSTEMTIME, 0,
      reinterpret_cast<LPARAM>(&time)) != GDT_VALID) return std::nullopt;
  date.wHour = time.wHour;
  date.wMinute = time.wMinute;
  date.wSecond = time.wSecond;
  date.wMilliseconds = 0;
  SYSTEMTIME utc{};
  if (TzSpecificLocalTimeToSystemTime(nullptr, &date, &utc) == FALSE) return std::nullopt;
  FILETIME fileTime{};
  if (SystemTimeToFileTime(&utc, &fileTime) == FALSE) return std::nullopt;
  ULARGE_INTEGER ticks{};
  ticks.LowPart = fileTime.dwLowDateTime;
  ticks.HighPart = fileTime.dwHighDateTime;
  constexpr ULONGLONG kUnixEpochTicks = 116444736000000000ull;
  return ticks.QuadPart >= kUnixEpochTicks
    ? static_cast<double>(ticks.QuadPart - kUnixEpochTicks) / 10000.0
    : -static_cast<double>(kUnixEpochTicks - ticks.QuadPart) / 10000.0;
}

[[nodiscard]] bool SetDateTime(
    const HWND window,
    const int dateId,
    const int timeId,
    const std::optional<double> milliseconds) {
  SYSTEMTIME local{};
  if (milliseconds.has_value()) {
    constexpr ULONGLONG kUnixEpochTicks = 116444736000000000ull;
    const long double ticksValue = static_cast<long double>(*milliseconds) * 10000.0L +
      static_cast<long double>(kUnixEpochTicks);
    if (ticksValue < 0.0L ||
        ticksValue > static_cast<long double>(std::numeric_limits<ULONGLONG>::max())) {
      SendDlgItemMessageW(window, dateId, DTM_SETSYSTEMTIME, GDT_NONE, 0);
      GetLocalTime(&local);
      SendDlgItemMessageW(window, timeId, DTM_SETSYSTEMTIME, GDT_VALID,
        reinterpret_cast<LPARAM>(&local));
      return false;
    }
    ULARGE_INTEGER ticks{};
    ticks.QuadPart = static_cast<ULONGLONG>(ticksValue);
    FILETIME fileTime{ticks.LowPart, ticks.HighPart};
    SYSTEMTIME utc{};
    if (FileTimeToSystemTime(&fileTime, &utc) != FALSE &&
        SystemTimeToTzSpecificLocalTime(nullptr, &utc, &local) != FALSE) {
      SendDlgItemMessageW(window, dateId, DTM_SETSYSTEMTIME, GDT_VALID,
        reinterpret_cast<LPARAM>(&local));
      SendDlgItemMessageW(window, timeId, DTM_SETSYSTEMTIME, GDT_VALID,
        reinterpret_cast<LPARAM>(&local));
      return true;
    }
  }
  SendDlgItemMessageW(window, dateId, DTM_SETSYSTEMTIME, GDT_NONE, 0);
  GetLocalTime(&local);
  SendDlgItemMessageW(window, timeId, DTM_SETSYSTEMTIME, GDT_VALID,
    reinterpret_cast<LPARAM>(&local));
  return !milliseconds.has_value();
}

[[nodiscard]] double UnixMilliseconds() noexcept {
  FILETIME fileTime{};
  GetSystemTimePreciseAsFileTime(&fileTime);
  ULARGE_INTEGER ticks{};
  ticks.LowPart = fileTime.dwLowDateTime;
  ticks.HighPart = fileTime.dwHighDateTime;
  constexpr ULONGLONG kUnixEpochTicks = 116444736000000000ull;
  return static_cast<double>(ticks.QuadPart - kUnixEpochTicks) / 10000.0;
}

[[nodiscard]] TokenContext PreviewTokenContext(const EditorState& state) {
  TokenContext context;
  context.name = state.draft.viewerName;
  context.nowMilliseconds = UnixMilliseconds();
  context.countdownTargetMilliseconds = state.draft.countdown.targetMilliseconds;
  context.runStartMilliseconds = context.nowMilliseconds;
  for (const auto& moment : state.draft.countdown.moments) {
    context.moments.insert_or_assign(moment.name, moment.targetMilliseconds);
  }
  return context;
}

HWND DatePicker(EditorState& state, const int id, const int x, const int y) {
  return AddControl(
    state, 0, DATETIMEPICK_CLASSW, L"",
    WS_TABSTOP | DTS_SHORTDATEFORMAT | DTS_SHOWNONE,
    x, y, 155, 24, id);
}

HWND TimePicker(EditorState& state, const int id, const int x, const int y) {
  return AddControl(
    state, 0, DATETIMEPICK_CLASSW, L"", WS_TABSTOP | DTS_TIMEFORMAT,
    x, y, 110, 24, id);
}

void DestroyPage(EditorState& state) {
  state.introPreviewRunning = false;
  state.introPreviewStartedTicks = 0;
  state.introPreviewOpacity = 1.0;
  for (const HWND control : state.pageControls) DestroyWindow(control);
  state.pageControls.clear();
}

[[nodiscard]] int ItemCount(const EditorState& state) {
  switch (state.page) {
    case Page::Intro: return static_cast<int>(state.draft.intro.lines.size());
    case Page::Messages: return static_cast<int>(state.draft.messages.messages.size());
    case Page::Images: return static_cast<int>(state.draft.images.images.size());
    case Page::Countdown: return static_cast<int>(state.draft.countdown.moments.size());
  }
  return 0;
}

void PopulateList(EditorState& state, int selection) {
  const HWND list = GetDlgItem(state.window, IdList);
  state.updating = true;
  SendMessageW(list, LB_RESETCONTENT, 0, 0);
  switch (state.page) {
    case Page::Intro:
      for (const auto& line : state.draft.intro.lines) {
        auto text = Wide(line.text);
        if (text.empty()) text = L"(blank line)";
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
      }
      break;
    case Page::Messages:
      for (const auto& message : state.draft.messages.messages) {
        auto text = Wide(message);
        if (text.empty()) text = L"(blank message)";
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
      }
      break;
    case Page::Images:
      for (const auto& image : state.draft.images.images) {
        std::wstring text = Wide(image.name) + L" (" + std::to_wstring(image.width) +
          L" x " + std::to_wstring(image.height) + L")";
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
      }
      break;
    case Page::Countdown:
      for (const auto& moment : state.draft.countdown.moments) {
        auto text = Wide(moment.name);
        if (text.empty()) text = L"(unnamed moment)";
        SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(text.c_str()));
      }
      break;
  }
  const int count = ItemCount(state);
  selection = count == 0 ? -1 : std::clamp(selection, 0, count - 1);
  state.selected = selection;
  SendMessageW(list, LB_SETCURSEL, selection, 0);
  state.updating = false;
}

void LoadSelected(EditorState& state) {
  const bool hasItem = state.selected >= 0 && state.selected < ItemCount(state);
  EnableWindow(GetDlgItem(state.window, IdRemove),
    hasItem && !(state.page == Page::Intro && ItemCount(state) == 1));
  EnableWindow(GetDlgItem(state.window, IdUp), hasItem && state.selected > 0);
  EnableWindow(GetDlgItem(state.window, IdDown),
    hasItem && state.selected + 1 < ItemCount(state));
  EnableWindow(GetDlgItem(state.window, IdText), hasItem);
  EnableWindow(GetDlgItem(state.window, IdName), hasItem);
  EnableWindow(GetDlgItem(state.window, IdItemDate), hasItem);
  EnableWindow(GetDlgItem(state.window, IdItemTime), hasItem);
  state.updating = true;
  switch (state.page) {
    case Page::Intro:
      if (hasItem) {
        const auto& line = state.draft.intro.lines[static_cast<std::size_t>(state.selected)];
        SetText(GetDlgItem(state.window, IdText), line.text);
        SetNumber(GetDlgItem(state.window, IdField5), line.holdMilliseconds);
        SetNumber(GetDlgItem(state.window, IdField6), line.pauseMilliseconds);
      } else {
        SetWindowTextW(GetDlgItem(state.window, IdText), L"");
      }
      break;
    case Page::Messages:
      SetText(GetDlgItem(state.window, IdText), hasItem
        ? state.draft.messages.messages[static_cast<std::size_t>(state.selected)] : "");
      break;
    case Page::Images:
      if (hasItem) {
        const auto& image = state.draft.images.images[static_cast<std::size_t>(state.selected)];
        SetText(GetDlgItem(state.window, IdName), image.name);
        const std::wstring dimensions = std::to_wstring(image.width) + L" x " +
          std::to_wstring(image.height) + L" luminance cells";
        SetWindowTextW(GetDlgItem(state.window, IdText), dimensions.c_str());
      } else {
        SetWindowTextW(GetDlgItem(state.window, IdName), L"");
        SetWindowTextW(GetDlgItem(state.window, IdText), L"No image selected");
      }
      break;
    case Page::Countdown:
      if (hasItem) {
        const auto& moment = state.draft.countdown.moments[static_cast<std::size_t>(state.selected)];
        SetText(GetDlgItem(state.window, IdName), moment.name);
        state.selectedDateRepresentable = SetDateTime(
          state.window, IdItemDate, IdItemTime, moment.targetMilliseconds);
      } else {
        SetWindowTextW(GetDlgItem(state.window, IdName), L"");
        state.selectedDateRepresentable = SetDateTime(
          state.window, IdItemDate, IdItemTime, std::nullopt);
      }
      state.selectedDateDirty = false;
      break;
  }
  state.updating = false;
}

void SaveSelected(EditorState& state) {
  if (state.updating || state.selected < 0 || state.selected >= ItemCount(state)) return;
  const auto index = static_cast<std::size_t>(state.selected);
  switch (state.page) {
    case Page::Intro: {
      auto& line = state.draft.intro.lines[index];
      line.text = TextValue(GetDlgItem(state.window, IdText), 120);
      line.holdMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField5), line.holdMilliseconds, 0.0, 20000.0);
      line.pauseMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField6), line.pauseMilliseconds, 0.0, 20000.0);
      break;
    }
    case Page::Messages:
      state.draft.messages.messages[index] = TextValue(GetDlgItem(state.window, IdText), 120);
      break;
    case Page::Images: {
      auto name = TextValue(GetDlgItem(state.window, IdName), 80);
      state.draft.images.images[index].name = name.empty() ? "Image" : std::move(name);
      break;
    }
    case Page::Countdown:
      state.draft.countdown.moments[index].name = TextValue(GetDlgItem(state.window, IdName), 40);
      if (state.selectedDateDirty) {
        state.draft.countdown.moments[index].targetMilliseconds =
          DateTimeValue(state.window, IdItemDate, IdItemTime);
      }
      break;
  }
}

void SaveGlobals(EditorState& state) {
  switch (state.page) {
    case Page::Intro:
      state.draft.intro.enabled = Checked(state.window, IdEnabled);
      state.draft.intro.rainDuringIntro = Checked(state.window, IdCheck2);
      state.draft.intro.charMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField1), state.draft.intro.charMilliseconds, 10.0, 500.0);
      state.draft.intro.startDelayMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField2), state.draft.intro.startDelayMilliseconds, 0.0, 10000.0);
      state.draft.intro.fadeOutMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField3), state.draft.intro.fadeOutMilliseconds, 0.0, 10000.0);
      state.draft.intro.postIntroDelayMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField4), state.draft.intro.postIntroDelayMilliseconds, 0.0, 10000.0);
      break;
    case Page::Messages:
      state.draft.messages.enabled = Checked(state.window, IdEnabled);
      state.draft.messages.flickerOut = Checked(state.window, IdCheck2);
      state.draft.messages.brightnessFade = Checked(state.window, IdCheck3);
      state.draft.messages.frequencyMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField1), state.draft.messages.frequencyMilliseconds, 500.0, 600000.0);
      state.draft.messages.persistenceMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField2), state.draft.messages.persistenceMilliseconds, 500.0, 600000.0);
      state.draft.messages.appearMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField3), state.draft.messages.appearMilliseconds, 0.0, 600000.0);
      state.draft.messages.disappearMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField4), state.draft.messages.disappearMilliseconds, 0.0, 600000.0);
      state.draft.messages.position = NumberValue(
        GetDlgItem(state.window, IdField5), state.draft.messages.position, 0.0, 1.0);
      state.draft.messages.jitter = NumberValue(
        GetDlgItem(state.window, IdField6), state.draft.messages.jitter, 0.0, 1.0);
      state.draft.messages.layout = SendDlgItemMessageW(
        state.window, IdCombo1, CB_GETCURSEL, 0, 0) == 1 ? MessageLayout::Drop : MessageLayout::Row;
      state.draft.messages.direction = SendDlgItemMessageW(
        state.window, IdCombo2, CB_GETCURSEL, 0, 0) == 1
        ? MessageDirection::BottomToTop : MessageDirection::TopToBottom;
      break;
    case Page::Images:
      state.draft.images.enabled = Checked(state.window, IdEnabled);
      state.draft.images.flickerOut = Checked(state.window, IdCheck2);
      state.draft.images.brightnessFade = Checked(state.window, IdCheck3);
      state.draft.images.frequencyMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField1), state.draft.images.frequencyMilliseconds, 500.0, 600000.0);
      state.draft.images.persistenceMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField2), state.draft.images.persistenceMilliseconds, 500.0, 600000.0);
      state.draft.images.appearMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField3), state.draft.images.appearMilliseconds, 0.0, 600000.0);
      state.draft.images.disappearMilliseconds = NumberValue(
        GetDlgItem(state.window, IdField4), state.draft.images.disappearMilliseconds, 0.0, 600000.0);
      state.draft.images.imageScale = NumberValue(
        GetDlgItem(state.window, IdField5), state.draft.images.imageScale, 0.05, 1.0);
      state.draft.images.placementJitter = NumberValue(
        GetDlgItem(state.window, IdField6), state.draft.images.placementJitter, 0.0, 1.0);
      break;
    case Page::Countdown:
      if (state.defaultDateDirty) {
        state.draft.countdown.targetMilliseconds =
          DateTimeValue(state.window, IdDefaultDate, IdDefaultTime);
      }
      break;
  }
}

void SavePage(EditorState& state) {
  SaveSelected(state);
  SaveGlobals(state);
}

void CreateListArea(EditorState& state, const wchar_t* addText) {
  AddControl(state, WS_EX_CLIENTEDGE, L"LISTBOX", L"",
    WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY, 24, 72, 258, 330, IdList);
  AddControl(state, 0, L"BUTTON", addText, WS_TABSTOP, 24, 411, 78, 28, IdAdd);
  AddControl(state, 0, L"BUTTON", L"Remove", WS_TABSTOP, 108, 411, 78, 28, IdRemove);
  AddControl(state, 0, L"BUTTON", L"Up", WS_TABSTOP, 192, 411, 42, 28, IdUp);
  AddControl(state, 0, L"BUTTON", L"Down", WS_TABSTOP, 240, 411, 52, 28, IdDown);
}

void BuildIntroPage(EditorState& state) {
  CreateListArea(state, L"Add line");
  SetChecked(Check(state, IdEnabled, L"Play intro", 315, 65), state.draft.intro.enabled);
  SetChecked(Check(state, IdCheck2, L"Rain during intro", 545, 65), state.draft.intro.rainDuringIntro);
  Label(state, L"Character delay (ms)", 315, 105);
  SetNumber(Edit(state, IdField1, 500, 102, 105, 10), state.draft.intro.charMilliseconds);
  Label(state, L"Start delay (ms)", 315, 139);
  SetNumber(Edit(state, IdField2, 500, 136, 105, 10), state.draft.intro.startDelayMilliseconds);
  Label(state, L"Fade out (ms)", 315, 173);
  SetNumber(Edit(state, IdField3, 500, 170, 105, 10), state.draft.intro.fadeOutMilliseconds);
  Label(state, L"Delay before rain (ms)", 315, 207);
  SetNumber(Edit(state, IdField4, 500, 204, 105, 10), state.draft.intro.postIntroDelayMilliseconds);
  Label(state, L"Selected line", 315, 255);
  Edit(state, IdText, 315, 278, 430, 120, true);
  Label(state, L"Hold (ms)", 315, 365, 90);
  Edit(state, IdField5, 405, 362, 100, 10);
  Label(state, L"Pause (ms)", 535, 365, 90);
  Edit(state, IdField6, 625, 362, 100, 10);
  AddControl(state, 0, L"BUTTON", L"Preview", WS_TABSTOP,
    315, 408, 80, 30, IdPreview);
  AddControl(state, 0, L"STATIC", L"Click Preview to play this draft.", SS_LEFT | SS_NOPREFIX,
    405, 402, 340, 72, IdPreviewText);
}

void BuildMessagesPage(EditorState& state) {
  CreateListArea(state, L"Add");
  SetChecked(Check(state, IdEnabled, L"Show rain messages", 315, 65), state.draft.messages.enabled);
  Label(state, L"Frequency / persistence (ms)", 315, 103, 200);
  SetNumber(Edit(state, IdField1, 520, 100, 100, 10), state.draft.messages.frequencyMilliseconds);
  SetNumber(Edit(state, IdField2, 630, 100, 100, 10), state.draft.messages.persistenceMilliseconds);
  Label(state, L"Appear / disappear (ms)", 315, 137, 200);
  SetNumber(Edit(state, IdField3, 520, 134, 100, 10), state.draft.messages.appearMilliseconds);
  SetNumber(Edit(state, IdField4, 630, 134, 100, 10), state.draft.messages.disappearMilliseconds);
  Label(state, L"Vertical position / jitter", 315, 171, 200);
  SetNumber(Edit(state, IdField5, 520, 168, 100, 10), state.draft.messages.position, 3);
  SetNumber(Edit(state, IdField6, 630, 168, 100, 10), state.draft.messages.jitter, 3);
  Label(state, L"Layout", 315, 205, 85);
  AddComboItems(Combo(state, IdCombo1, 405, 202, 130), {L"Row", L"Drop"},
    state.draft.messages.layout == MessageLayout::Drop ? 1 : 0);
  Label(state, L"Direction", 550, 205, 75);
  AddComboItems(Combo(state, IdCombo2, 625, 202, 120), {L"Top to bottom", L"Bottom to top"},
    state.draft.messages.direction == MessageDirection::BottomToTop ? 1 : 0);
  SetChecked(Check(state, IdCheck2, L"Flicker out", 315, 242, 150), state.draft.messages.flickerOut);
  SetChecked(Check(state, IdCheck3, L"Brightness fade", 490, 242, 170), state.draft.messages.brightnessFade);
  Label(state, L"Selected message", 315, 285);
  Edit(state, IdText, 315, 308, 430, 120, true);
}

void BuildImagesPage(EditorState& state) {
  CreateListArea(state, L"Import...");
  AddControl(state, 0, L"BUTTON", L"Max visibility", WS_TABSTOP,
    24, 447, 126, 28, IdMaxVisibility);
  SetChecked(Check(state, IdEnabled, L"Show image reveals", 315, 65), state.draft.images.enabled);
  Label(state, L"Frequency / persistence (ms)", 315, 103, 200);
  SetNumber(Edit(state, IdField1, 520, 100, 100, 10), state.draft.images.frequencyMilliseconds);
  SetNumber(Edit(state, IdField2, 630, 100, 100, 10), state.draft.images.persistenceMilliseconds);
  Label(state, L"Appear / disappear (ms)", 315, 137, 200);
  SetNumber(Edit(state, IdField3, 520, 134, 100, 10), state.draft.images.appearMilliseconds);
  SetNumber(Edit(state, IdField4, 630, 134, 100, 10), state.draft.images.disappearMilliseconds);
  Label(state, L"Scale / placement jitter", 315, 171, 200);
  SetNumber(Edit(state, IdField5, 520, 168, 100, 10), state.draft.images.imageScale, 3);
  SetNumber(Edit(state, IdField6, 630, 168, 100, 10), state.draft.images.placementJitter, 3);
  SetChecked(Check(state, IdCheck2, L"Flicker out", 315, 210, 150), state.draft.images.flickerOut);
  SetChecked(Check(state, IdCheck3, L"Brightness fade", 490, 210, 170), state.draft.images.brightnessFade);
  Label(state, L"Selected image name", 315, 266);
  Edit(state, IdName, 315, 289, 430, 80);
  Label(state, L"Dimensions", 315, 332);
  AddControl(state, 0, L"STATIC", L"", 0, 405, 335, 310, 22, IdText);
  Label(state, L"PNG, JPEG, GIF, BMP and other installed WIC codecs are supported.", 315, 380, 430);
}

void BuildCountdownPage(EditorState& state) {
  CreateListArea(state, L"Add moment");
  Label(state, L"Default countdown/countup target (optional)", 315, 70, 330);
  DatePicker(state, IdDefaultDate, 315, 96);
  TimePicker(state, IdDefaultTime, 480, 96);
  state.defaultDateRepresentable = SetDateTime(
    state.window, IdDefaultDate, IdDefaultTime, state.draft.countdown.targetMilliseconds);
  state.defaultDateDirty = false;
  Label(state, L"Use {countdown} or {countup} in intro and message text.", 315, 132, 430);
  Label(state, L"Extended dates outside the Windows picker range are preserved until replaced.",
    315, 158, 430);
  Label(state, L"Selected moment name", 315, 198);
  Edit(state, IdName, 315, 221, 430, 40);
  Label(state, L"Selected moment target (optional)", 315, 268, 300);
  DatePicker(state, IdItemDate, 315, 294);
  TimePicker(state, IdItemTime, 480, 294);
  Label(state, L"Use {countdown:NAME} or {countup:NAME}; names must be unique.", 315, 337, 430);
  Label(state, L"Live token preview", 315, 374, 180);
  AddControl(state, 0, L"STATIC", L"", SS_LEFT | SS_NOPREFIX,
    315, 397, 430, 60, IdLivePreview);
}

void BuildPage(EditorState& state) {
  switch (state.page) {
    case Page::Intro: BuildIntroPage(state); break;
    case Page::Messages: BuildMessagesPage(state); break;
    case Page::Images: BuildImagesPage(state); break;
    case Page::Countdown: BuildCountdownPage(state); break;
  }
  PopulateList(state, state.selected);
  LoadSelected(state);
}

template <typename T>
void MoveItem(std::vector<T>& values, const int from, const int to) {
  if (from < 0 || to < 0 || from >= static_cast<int>(values.size()) ||
      to >= static_cast<int>(values.size())) return;
  std::swap(values[static_cast<std::size_t>(from)], values[static_cast<std::size_t>(to)]);
}

void AddItem(EditorState& state) {
  SavePage(state);
  switch (state.page) {
    case Page::Intro:
      if (state.draft.intro.lines.size() < kMaximumLines)
        state.draft.intro.lines.push_back({"New intro line", 2800.0, 0.0});
      break;
    case Page::Messages:
      if (state.draft.messages.messages.size() < kMaximumMessages)
        state.draft.messages.messages.push_back("NEW MESSAGE");
      break;
    case Page::Images: {
      const std::size_t remaining = kMaximumImages - state.draft.images.images.size();
      std::size_t failures = 0;
      auto images = PickAndImportImageMasks(state.window, remaining, &failures);
      for (auto& image : images) state.draft.images.images.push_back(std::move(image));
      if (failures != 0) {
        const auto message = std::to_wstring(failures) +
          L" selected image(s) could not be decoded by Windows Imaging Component.";
        MessageBoxW(state.window, message.c_str(), L"Matrix Code image import", MB_OK | MB_ICONWARNING);
      }
      break;
    }
    case Page::Countdown:
      if (state.draft.countdown.moments.size() < kMaximumMoments)
        state.draft.countdown.moments.push_back({"moment", std::nullopt});
      break;
  }
  PopulateList(state, ItemCount(state) - 1);
  LoadSelected(state);
}

void RemoveItem(EditorState& state) {
  SavePage(state);
  if (state.selected < 0 || state.selected >= ItemCount(state)) return;
  const auto index = static_cast<std::size_t>(state.selected);
  switch (state.page) {
    case Page::Intro:
      if (state.draft.intro.lines.size() > 1) state.draft.intro.lines.erase(state.draft.intro.lines.begin() + index);
      break;
    case Page::Messages: state.draft.messages.messages.erase(state.draft.messages.messages.begin() + index); break;
    case Page::Images: state.draft.images.images.erase(state.draft.images.images.begin() + index); break;
    case Page::Countdown: state.draft.countdown.moments.erase(state.draft.countdown.moments.begin() + index); break;
  }
  PopulateList(state, std::min(state.selected, ItemCount(state) - 1));
  LoadSelected(state);
}

void MoveSelected(EditorState& state, const int direction) {
  SavePage(state);
  const int target = state.selected + direction;
  if (state.selected < 0 || target < 0 || target >= ItemCount(state)) return;
  switch (state.page) {
    case Page::Intro: MoveItem(state.draft.intro.lines, state.selected, target); break;
    case Page::Messages: MoveItem(state.draft.messages.messages, state.selected, target); break;
    case Page::Images: MoveItem(state.draft.images.images, state.selected, target); break;
    case Page::Countdown: MoveItem(state.draft.countdown.moments, state.selected, target); break;
  }
  PopulateList(state, target);
  LoadSelected(state);
}

void ResetPage(EditorState& state) {
  const auto defaults = DefaultSettings();
  switch (state.page) {
    case Page::Intro: state.draft.intro = defaults.intro; break;
    case Page::Messages: state.draft.messages = defaults.messages; break;
    case Page::Images: state.draft.images = defaults.images; break;
    case Page::Countdown: state.draft.countdown = defaults.countdown; break;
  }
  state.selected = 0;
  DestroyPage(state);
  BuildPage(state);
}

void ApplyMaximumImageVisibility(EditorState& state) {
  SavePage(state);
  auto& images = state.draft.images;
  images.enabled = true;
  images.frequencyMilliseconds = 500.0;
  images.persistenceMilliseconds = 60000.0;
  images.appearMilliseconds = 0.0;
  images.disappearMilliseconds = 0.0;
  images.flickerOut = false;
  images.brightnessFade = false;
  images.imageScale = 1.0;
  images.placementJitter = 0.0;
  auto& controls = state.draft.controls;
  controls.density = 90.0;
  controls.rampUpMilliseconds = 0.0;
  controls.trailLength = 0.45;
  controls.trailVariation = 0.2;
  controls.speed = 0.6;
  controls.glyphScale = 0.7;
  controls.glow = 0.6;
  controls.leadBrightness = 1.0;
  controls.vignette = 0.0;
  controls.scanlines = false;
  controls.allowOverlap = false;
  controls.quality = QualityTier::High;
  controls.glyphMode = GlyphMode::Latin;
  controls.glyphFont = GlyphFont::Mono;
  controls.glyphRate = 1.0;
  controls.mirror = false;
  DestroyPage(state);
  BuildPage(state);
}

void StartIntroPreview(EditorState& state) {
  if (state.page != Page::Intro) return;
  SavePage(state);
  state.introPreviewRunning = true;
  state.introPreviewStartedTicks = GetTickCount64();
  state.introPreviewRunStartMilliseconds = UnixMilliseconds();
  state.introPreviewOpacity = 1.0;
  SetWindowTextW(GetDlgItem(state.window, IdPreview), L"Replay");
}

void UpdateIntroPreview(EditorState& state) {
  if (state.page != Page::Intro || !state.introPreviewRunning) return;
  const double elapsedMilliseconds = static_cast<double>(
    GetTickCount64() - state.introPreviewStartedTicks);
  auto lines = state.draft.intro.lines;
  TokenContext context = PreviewTokenContext(state);
  context.runStartMilliseconds = state.introPreviewRunStartMilliseconds;
  context.framesPerSecond = 60.0;
  for (auto& line : lines) line.text = ResolveTokens(line.text, context);
  const auto preview = ComputeIntroTimeline(
    lines,
    state.draft.intro.charMilliseconds,
    state.draft.intro.startDelayMilliseconds,
    state.draft.intro.fadeOutMilliseconds,
    elapsedMilliseconds);
  const HWND output = GetDlgItem(state.window, IdPreviewText);
  if (preview.done) {
    state.introPreviewRunning = false;
    state.introPreviewOpacity = 1.0;
    SetWindowTextW(output, L"Preview complete. Click Replay to run it again.");
  } else {
    std::string text = preview.visibleText;
    text += IntroCursorVisible(elapsedMilliseconds) ? "\xE2\x96\x88" : " ";
    const auto display = Wide(text);
    SetWindowTextW(output, display.c_str());
    state.introPreviewOpacity = std::clamp(preview.opacity, 0.0, 1.0);
  }
  InvalidateRect(output, nullptr, TRUE);
}

void UpdateCountdownPreview(EditorState& state) {
  if (state.page != Page::Countdown) return;
  TokenContext context = PreviewTokenContext(state);
  if (state.defaultDateDirty) {
    context.countdownTargetMilliseconds = DateTimeValue(
      state.window, IdDefaultDate, IdDefaultTime);
  }
  std::string preview = "Countdown  " + ResolveTokens("{countdown}", context) +
    "\r\nCountup       " + ResolveTokens("{countup}", context);
  if (state.selected >= 0 &&
      state.selected < static_cast<int>(state.draft.countdown.moments.size())) {
    const auto index = static_cast<std::size_t>(state.selected);
    std::string name = TextValue(GetDlgItem(state.window, IdName), 40);
    if (name.empty()) name = state.draft.countdown.moments[index].name;
    auto target = state.draft.countdown.moments[index].targetMilliseconds;
    if (state.selectedDateDirty) {
      target = DateTimeValue(state.window, IdItemDate, IdItemTime);
    }
    context.moments.insert_or_assign(name, target);
    preview += "\r\n" + name + "  " + ResolveTokens("{countdown:" + name + "}", context) +
      " / " + ResolveTokens("{countup:" + name + "}", context);
  }
  const auto display = Wide(preview);
  const HWND output = GetDlgItem(state.window, IdLivePreview);
  SetWindowTextW(output, display.c_str());
  InvalidateRect(output, nullptr, TRUE);
}

LRESULT CALLBACK WindowProcedure(
    HWND window, const UINT message, const WPARAM wParam, const LPARAM lParam) {
  auto* state = reinterpret_cast<EditorState*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
    state = static_cast<EditorState*>(create->lpCreateParams);
    state->window = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(state));
  }
  switch (message) {
    case WM_CREATE: {
      state->dpi = std::max(96u, GetDpiForWindow(window));
      state->font = CreateUiFont(state->dpi);
      state->previewBackground = CreateSolidBrush(RGB(0, 0, 0));
      state->tab = CreateWindowExW(
        0, WC_TABCONTROLW, L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        Scale(12, state->dpi), Scale(12, state->dpi),
        Scale(780, state->dpi), Scale(492, state->dpi), window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(IdTab)), GetModuleHandleW(nullptr), nullptr);
      ApplyFont(state->tab, state->font);
      constexpr std::array<const wchar_t*, 4> names{L"Intro", L"Messages", L"Images", L"Countdown"};
      for (int index = 0; index < static_cast<int>(names.size()); ++index) {
        TCITEMW item{};
        item.mask = TCIF_TEXT;
        item.pszText = const_cast<wchar_t*>(names[static_cast<std::size_t>(index)]);
        TabCtrl_InsertItem(state->tab, index, &item);
      }
      TabCtrl_SetCurSel(state->tab, static_cast<int>(state->page));
      CreateWindowExW(0, L"BUTTON", L"Reset this section", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        Scale(16, state->dpi), Scale(522, state->dpi),
        Scale(142, state->dpi), Scale(30, state->dpi), window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(IdResetSection)), GetModuleHandleW(nullptr), nullptr);
      CreateWindowExW(0, L"BUTTON", L"Cancel", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
        Scale(592, state->dpi), Scale(522, state->dpi),
        Scale(92, state->dpi), Scale(30, state->dpi), window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(IdCancel)), GetModuleHandleW(nullptr), nullptr);
      CreateWindowExW(0, L"BUTTON", L"Apply", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
        Scale(692, state->dpi), Scale(522, state->dpi),
        Scale(92, state->dpi), Scale(30, state->dpi), window,
        reinterpret_cast<HMENU>(static_cast<INT_PTR>(IdSave)), GetModuleHandleW(nullptr), nullptr);
      ApplyFont(GetDlgItem(window, IdResetSection), state->font);
      ApplyFont(GetDlgItem(window, IdCancel), state->font);
      ApplyFont(GetDlgItem(window, IdSave), state->font);
      BuildPage(*state);
      ShowScrollBar(window, SB_BOTH, FALSE);
      UpdateScrollRange(*state);
      SetTimer(window, kPreviewTimer, 50u, nullptr);
      return 0;
    }
    case WM_SIZE:
      UpdateScrollRange(*state);
      return 0;
    case WM_HSCROLL:
    case WM_VSCROLL: {
      if (lParam != 0) return 0;
      const int bar = message == WM_HSCROLL ? SB_HORZ : SB_VERT;
      SCROLLINFO info{sizeof(info), SIF_ALL};
      GetScrollInfo(window, bar, &info);
      int next = bar == SB_HORZ
        ? state->horizontalScrollPosition
        : state->scrollPosition;
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
      SetScrollPosition(
        *state,
        bar == SB_HORZ ? next : state->horizontalScrollPosition,
        bar == SB_VERT ? next : state->scrollPosition);
      return 0;
    }
    case WM_MOUSEWHEEL: {
      const int detents = GET_WHEEL_DELTA_WPARAM(wParam) / WHEEL_DELTA;
      SetScrollPosition(
        *state, state->horizontalScrollPosition,
        state->scrollPosition - detents * Scale(72, state->dpi));
      return 0;
    }
    case WM_DPICHANGED: {
      const UINT nextDpi = std::max<UINT>(96u, static_cast<UINT>(HIWORD(wParam)));
      SetScrollPosition(*state, 0, 0);
      const auto* suggested = reinterpret_cast<const RECT*>(lParam);
      SetWindowPos(window, nullptr, suggested->left, suggested->top,
        suggested->right - suggested->left, suggested->bottom - suggested->top,
        SWP_NOACTIVATE | SWP_NOZORDER);
      RescaleChildren(window, state->dpi, nextDpi);
      state->dpi = nextDpi;
      ReplaceUiFont(*state, state->dpi);
      UpdateScrollRange(*state);
      return 0;
    }
    case WM_TIMER:
      if (wParam == kPreviewTimer) {
        UpdateIntroPreview(*state);
        UpdateCountdownPreview(*state);
        return 0;
      }
      break;
    case WM_CTLCOLORSTATIC: {
      const HWND control = reinterpret_cast<HWND>(lParam);
      const int id = GetDlgCtrlID(control);
      if (id == IdPreviewText || id == IdLivePreview) {
        const HDC device = reinterpret_cast<HDC>(wParam);
        const double opacity = id == IdPreviewText ? state->introPreviewOpacity : 1.0;
        SetBkColor(device, RGB(0, 0, 0));
        SetTextColor(device, RGB(
          0,
          static_cast<BYTE>(std::lround(255.0 * opacity)),
          static_cast<BYTE>(std::lround(65.0 * opacity))));
        return reinterpret_cast<LRESULT>(state->previewBackground);
      }
      break;
    }
    case WM_NOTIFY: {
      const auto* header = reinterpret_cast<const NMHDR*>(lParam);
      if (!state->updating && header->code == DTN_DATETIMECHANGE) {
        if (header->idFrom == IdDefaultDate || header->idFrom == IdDefaultTime) {
          state->defaultDateDirty = true;
        }
        if (header->idFrom == IdItemDate || header->idFrom == IdItemTime) {
          state->selectedDateDirty = true;
        }
      }
      if (header->idFrom == IdTab && header->code == TCN_SELCHANGE) {
        SavePage(*state);
        DestroyPage(*state);
        state->introPreviewRunning = false;
        state->introPreviewOpacity = 1.0;
        state->page = static_cast<Page>(TabCtrl_GetCurSel(state->tab));
        state->selected = 0;
        BuildPage(*state);
        return 0;
      }
      break;
    }
    case WM_COMMAND:
      if (LOWORD(wParam) == IdList && HIWORD(wParam) == LBN_SELCHANGE && !state->updating) {
        const int next = static_cast<int>(SendDlgItemMessageW(window, IdList, LB_GETCURSEL, 0, 0));
        SaveSelected(*state);
        PopulateList(*state, next);
        LoadSelected(*state);
        return 0;
      }
      switch (LOWORD(wParam)) {
        case IdPreview: StartIntroPreview(*state); return 0;
        case IdAdd: AddItem(*state); return 0;
        case IdRemove: RemoveItem(*state); return 0;
        case IdUp: MoveSelected(*state, -1); return 0;
        case IdDown: MoveSelected(*state, 1); return 0;
        case IdMaxVisibility: ApplyMaximumImageVisibility(*state); return 0;
        case IdResetSection: ResetPage(*state); return 0;
        case IdCancel: DestroyWindow(window); return 0;
        case IdSave:
          SavePage(*state);
          *state->destination = SanitizeSettings(EncodeSettings(state->draft));
          state->result = IDOK;
          DestroyWindow(window);
          return 0;
      }
      break;
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      KillTimer(window, kPreviewTimer);
      if (state->previewBackground != nullptr) {
        DeleteObject(state->previewBackground);
        state->previewBackground = nullptr;
      }
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

INT_PTR DocumentEditor::ShowModal(
    HWND owner,
    SettingsSnapshot& settings,
    const DocumentPage initialPage) {
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_TAB_CLASSES | ICC_DATE_CLASSES};
  InitCommonControlsEx(&controls);
  WNDCLASSEXW windowClass{sizeof(windowClass)};
  windowClass.lpfnWndProc = WindowProcedure;
  windowClass.hInstance = GetModuleHandleW(nullptr);
  windowClass.hIcon = LoadIconW(windowClass.hInstance, MAKEINTRESOURCEW(IDI_MATRIXCODE_ICON));
  windowClass.hIconSm = windowClass.hIcon;
  windowClass.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  windowClass.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  windowClass.lpszClassName = kClassName;
  RegisterClassExW(&windowClass);

  EditorState state;
  state.destination = &settings;
  state.draft = settings;
  state.page = initialPage;
  state.selected = 0;
  state.owner = owner;
  if (owner != nullptr) EnableWindow(owner, FALSE);
  const UINT dpi = OwnerDpi(owner);
  const RECT workArea = MonitorWorkArea(owner);
  const int width = std::min<int>(Scale(820, dpi), workArea.right - workArea.left);
  const int height = std::min<int>(Scale(600, dpi), workArea.bottom - workArea.top);
  HWND window = CreateWindowExW(
    WS_EX_DLGMODALFRAME | WS_EX_CONTROLPARENT, kClassName,
    L"Matrix Code - Intro, messages, images, and countdown",
    WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_HSCROLL | WS_VSCROLL | WS_VISIBLE,
    workArea.left + std::max<LONG>(0L, ((workArea.right - workArea.left) - width) / 2),
    workArea.top + std::max<LONG>(0L, ((workArea.bottom - workArea.top) - height) / 2),
    width, height,
    owner, nullptr, GetModuleHandleW(nullptr), &state);
  if (window == nullptr) {
    if (owner != nullptr) EnableWindow(owner, TRUE);
    return -1;
  }
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
