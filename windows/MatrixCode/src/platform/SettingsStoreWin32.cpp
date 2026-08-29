#include "matrixcode/platform/SettingsStoreWin32.h"

#include <algorithm>
#include <array>
#include <cwctype>
#include <fstream>
#include <iterator>
#include <windows.h>
#include <knownfolders.h>
#include <shlobj.h>

#include "matrixcode/core/Settings.h"
#include "matrixcode/platform/Win32Utf.h"

namespace matrixcode::platform {
namespace {

constexpr std::uint64_t kMaximumSettingsBytes = 8u * 1024u * 1024u;

class MutexLock final {
 public:
  MutexLock() : mutex_(CreateMutexW(nullptr, FALSE, L"Local\\MatrixCode.Settings.v1")) {
    if (mutex_ != nullptr) {
      const DWORD result = WaitForSingleObject(mutex_, 2000);
      locked_ = result == WAIT_OBJECT_0 || result == WAIT_ABANDONED;
    }
  }
  ~MutexLock() {
    if (locked_) ReleaseMutex(mutex_);
    if (mutex_ != nullptr) CloseHandle(mutex_);
  }
  [[nodiscard]] bool Locked() const noexcept { return locked_; }
 private:
  HANDLE mutex_ = nullptr;
  bool locked_ = false;
};

[[nodiscard]] std::filesystem::path LocalAppData() {
  PWSTR value = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &value))) {
    return std::filesystem::temp_directory_path();
  }
  const std::filesystem::path result(value);
  CoTaskMemFree(value);
  return result;
}

[[nodiscard]] std::wstring Win32Message(const DWORD error) {
  wchar_t* buffer = nullptr;
  const DWORD length = FormatMessageW(
    FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
    nullptr, error, 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  std::wstring result = length != 0 && buffer != nullptr
    ? std::wstring(buffer, length)
    : L"Windows error " + std::to_wstring(error);
  if (buffer != nullptr) LocalFree(buffer);
  return result;
}

}  // namespace

SettingsStoreWin32::SettingsStoreWin32()
    : directory_(LocalAppData() / L"MatrixCode"), filePath_(directory_ / L"settings.json") {}

SettingsSnapshot SettingsStoreWin32::Load(std::wstring* diagnostic) const {
  SettingsSnapshot fallback = DefaultSettings();
  fallback.viewerName = DefaultViewerName();
  MutexLock lock;
  if (!lock.Locked()) {
    if (diagnostic != nullptr) *diagnostic = L"Timed out waiting for the settings lock.";
    return fallback;
  }
  std::error_code error;
  if (!std::filesystem::exists(filePath_, error)) return fallback;
  const auto size = std::filesystem::file_size(filePath_, error);
  if (error || size > kMaximumSettingsBytes) {
    if (diagnostic != nullptr) *diagnostic = L"The settings file is unreadable or exceeds 8 MiB.";
    return fallback;
  }
  std::ifstream stream(filePath_, std::ios::binary);
  std::string content((std::istreambuf_iterator<char>(stream)), std::istreambuf_iterator<char>());
  std::string parseError;
  auto decoded = DecodeSettings(content, &parseError);
  if (!decoded.has_value()) {
    if (diagnostic != nullptr) {
      *diagnostic = L"Invalid settings JSON; defaults were loaded.";
    }
    return fallback;
  }
  if (decoded->viewerName.empty()) decoded->viewerName = fallback.viewerName;
  return *decoded;
}

bool SettingsStoreWin32::Save(const SettingsSnapshot& settings, std::wstring* diagnostic) const {
  MutexLock lock;
  if (!lock.Locked()) {
    if (diagnostic != nullptr) *diagnostic = L"Timed out waiting for the settings lock.";
    return false;
  }
  std::error_code error;
  std::filesystem::create_directories(directory_, error);
  if (error) {
    if (diagnostic != nullptr) *diagnostic = L"Could not create the settings directory.";
    return false;
  }
  const std::string encoded = EncodeSettingsUtf8(settings, true);
  const auto temporary = filePath_.wstring() + L".tmp";
  HANDLE file = CreateFileW(
    temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
    FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    if (diagnostic != nullptr) *diagnostic = Win32Message(GetLastError());
    return false;
  }
  DWORD writeError = ERROR_SUCCESS;
  DWORD written = 0;
  bool wrote = false;
  if (encoded.size() > MAXDWORD) {
    writeError = ERROR_FILE_TOO_LARGE;
  } else if (WriteFile(
      file, encoded.data(), static_cast<DWORD>(encoded.size()), &written, nullptr) == FALSE) {
    writeError = GetLastError();
  } else if (written != static_cast<DWORD>(encoded.size())) {
    writeError = ERROR_WRITE_FAULT;
  } else if (FlushFileBuffers(file) == FALSE) {
    writeError = GetLastError();
  } else {
    wrote = true;
  }
  CloseHandle(file);
  if (!wrote) {
    if (diagnostic != nullptr) *diagnostic = Win32Message(writeError);
    DeleteFileW(temporary.c_str());
    return false;
  }
  const auto backup = filePath_.wstring() + L".bak";
  BOOL replaced = ReplaceFileW(
    filePath_.c_str(), temporary.c_str(), backup.c_str(), REPLACEFILE_WRITE_THROUGH, nullptr, nullptr);
  if (!replaced && GetLastError() == ERROR_FILE_NOT_FOUND) {
    replaced = MoveFileExW(
      temporary.c_str(), filePath_.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
  }
  if (!replaced) {
    if (diagnostic != nullptr) *diagnostic = Win32Message(GetLastError());
    DeleteFileW(temporary.c_str());
    return false;
  }
  return true;
}

std::string SettingsStoreWin32::DefaultViewerName() {
  std::array<wchar_t, 256> buffer{};
  DWORD size = static_cast<DWORD>(buffer.size());
  std::wstring name;
  if (GetUserNameW(buffer.data(), &size) != FALSE) {
    name.assign(buffer.data());
  } else {
    PWSTR profile = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &profile))) {
      name = std::filesystem::path(profile).filename().wstring();
      CoTaskMemFree(profile);
    }
  }
  while (!name.empty() && std::iswspace(name.front())) name.erase(name.begin());
  while (!name.empty() && std::iswspace(name.back())) name.pop_back();
  if (name.empty()) return "Neo";
  const int scalarUnits = name.size() >= 2 && name[0] >= 0xd800 && name[0] <= 0xdbff &&
      name[1] >= 0xdc00 && name[1] <= 0xdfff
    ? 2
    : 1;
  const int upperLength = LCMapStringEx(
    LOCALE_NAME_USER_DEFAULT, LCMAP_UPPERCASE, name.data(), scalarUnits,
    nullptr, 0, nullptr, nullptr, 0);
  if (upperLength > 0) {
    std::wstring upper(static_cast<std::size_t>(upperLength), L'\0');
    if (LCMapStringEx(
          LOCALE_NAME_USER_DEFAULT, LCMAP_UPPERCASE, name.data(), scalarUnits,
          upper.data(), upperLength, nullptr, nullptr, 0) == upperLength) {
      name.replace(0, static_cast<std::size_t>(scalarUnits), upper);
    }
  }
  const auto result = Utf8FromWide(name);
  return result.empty() ? "Neo" : result;
}

}  // namespace matrixcode::platform
