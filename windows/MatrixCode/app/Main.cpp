#include <commctrl.h>
#include <shellapi.h>
#include <string>
#include <vector>
#include <windows.h>

#include "matrixcode/platform/SettingsStoreWin32.h"
#include "matrixcode/platform/SettingsWindow.h"
#include "matrixcode/platform/Win32Host.h"

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
  matrixcode::platform::EnablePerMonitorV2DpiAwareness();
  const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES | ICC_BAR_CLASSES};
  InitCommonControlsEx(&controls);

  int count = 0;
  LPWSTR* values = CommandLineToArgvW(GetCommandLineW(), &count);
  bool settingsOnly = false;
  bool forceWarp = false;
  bool spanDisplays = false;
  for (int index = 1; index < count; ++index) {
    const std::wstring argument(values[index]);
    if (argument == L"--settings") settingsOnly = true;
    if (argument == L"--warp") forceWarp = true;
    if (argument == L"--multi-monitor") spanDisplays = true;
  }
  if (values != nullptr) LocalFree(values);

  int result = 0;
  if (settingsOnly) {
    matrixcode::platform::SettingsStoreWin32 store;
    result = matrixcode::platform::SettingsWindow::ShowModal(nullptr, store) == -1 ? 1 : 0;
  } else {
    result = matrixcode::platform::RunWin32Host(
      instance, {matrixcode::platform::HostMode::Standalone, nullptr, forceWarp, spanDisplays});
  }
  if (SUCCEEDED(com)) CoUninitialize();
  return result;
}
