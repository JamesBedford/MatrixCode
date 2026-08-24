#include <windows.h>
#include <commctrl.h>
#include <objbase.h>
#include <shellapi.h>
#include <string>
#include <vector>

#include "matrixcode/platform/ScreenSaverArgs.h"
#include "matrixcode/platform/SettingsStoreWin32.h"
#include "matrixcode/platform/SettingsWindow.h"
#include "matrixcode/platform/Win32Host.h"

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  matrixcode::platform::EnablePerMonitorV2DpiAwareness();
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_BAR_CLASSES};
  InitCommonControlsEx(&controls);

  int count = 0;
  LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &count);
  std::vector<std::wstring> arguments;
  for (int index = 1; raw != nullptr && index < count; ++index) arguments.emplace_back(raw[index]);
  if (raw != nullptr) LocalFree(raw);
  const auto parsed = matrixcode::platform::ParseScreenSaverArguments(arguments);
  int result = 0;
  if (!parsed.valid) {
    result = 1;
  } else if (parsed.mode == matrixcode::platform::ScreenSaverMode::Configure) {
    HWND owner = reinterpret_cast<HWND>(parsed.ownerWindow);
    if (owner != nullptr && !IsWindow(owner)) owner = nullptr;
    matrixcode::platform::SettingsStoreWin32 store;
    result = matrixcode::platform::SettingsWindow::ShowModal(owner, store) == -1 ? 1 : 0;
  } else {
    result = matrixcode::platform::RunWin32Host(instance, {
      parsed.mode == matrixcode::platform::ScreenSaverMode::Preview
        ? matrixcode::platform::HostMode::Preview
        : matrixcode::platform::HostMode::ScreenSaver,
      reinterpret_cast<HWND>(parsed.ownerWindow),
      false,
      false,
    });
  }
  if (SUCCEEDED(com)) CoUninitialize();
  return result;
}
