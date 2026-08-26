#include "matrixcode/platform/Win32Host.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <limits>
#include <memory>
#include <iomanip>
#include <sstream>
#include <span>
#include <string>
#include <string_view>
#include <system_error>
#include <utility>
#include <vector>

#include <dwmapi.h>
#include <dxgi.h>
#include <bcrypt.h>

#include "matrixcode/core/Controllers.h"
#include "matrixcode/core/DisplayTopology.h"
#include "matrixcode/core/ImageReveal.h"
#include "matrixcode/core/IntroTimeline.h"
#include "matrixcode/core/MessageScheduler.h"
#include "matrixcode/core/RainSimulation.h"
#include "matrixcode/core/Rng.h"
#include "matrixcode/core/TokenResolver.h"
#include "matrixcode/render/D3D11Renderer.h"
#include "matrixcode/platform/SettingsStoreWin32.h"
#include "matrixcode/platform/SettingsWindow.h"
#include "matrixcode/platform/DocumentEditor.h"
#include "resource.h"

namespace matrixcode::platform {
namespace {

constexpr wchar_t kWindowClass[] = L"MatrixCode.Native.RenderWindow";
constexpr std::uint32_t kNormalSeed = 0x001a2b3cu;
constexpr std::size_t kMaximumRainLanes = 8;
constexpr UINT_PTR kSettledClickTimer = 1u;
constexpr UINT kMultiClickMilliseconds = 350u;
constexpr std::uint32_t kPauseUser = 1u << 0u;
constexpr std::uint32_t kPauseReducedMotion = 1u << 1u;
constexpr std::uint32_t kPauseModal = 1u << 2u;
constexpr std::uint32_t kPauseSystem = 1u << 3u;
constexpr wchar_t kUiStateRegistryKey[] = L"Software\\MatrixCode";
constexpr wchar_t kHudRegistryValue[] = L"FpsOverlayVisible";

[[nodiscard]] bool LoadHudVisible() noexcept {
  DWORD value = 0;
  DWORD size = static_cast<DWORD>(sizeof(value));
  return RegGetValueW(
    HKEY_CURRENT_USER, kUiStateRegistryKey, kHudRegistryValue,
    RRF_RT_REG_DWORD, nullptr, &value, &size) == ERROR_SUCCESS && value != 0;
}

void SaveHudVisible(const bool visible) noexcept {
  HKEY key = nullptr;
  if (RegCreateKeyExW(
        HKEY_CURRENT_USER, kUiStateRegistryKey, 0, nullptr, 0, KEY_SET_VALUE,
        nullptr, &key, nullptr) != ERROR_SUCCESS) return;
  const DWORD value = visible ? 1u : 0u;
  RegSetValueExW(
    key, kHudRegistryValue, 0, REG_DWORD,
    reinterpret_cast<const BYTE*>(&value), static_cast<DWORD>(sizeof(value)));
  RegCloseKey(key);
}

[[nodiscard]] double UnixSeconds() noexcept {
  FILETIME fileTime{};
  GetSystemTimePreciseAsFileTime(&fileTime);
  ULARGE_INTEGER value{};
  value.LowPart = fileTime.dwLowDateTime;
  value.HighPart = fileTime.dwHighDateTime;
  constexpr std::uint64_t epoch = 116444736000000000ull;
  return static_cast<double>(value.QuadPart - epoch) / 10000000.0;
}

[[nodiscard]] std::uint32_t RandomSessionSeed() noexcept {
  std::uint32_t seed = 0;
  if (BCryptGenRandom(
        nullptr, reinterpret_cast<PUCHAR>(&seed), static_cast<ULONG>(sizeof(seed)),
        BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0 && seed != 0) return seed;
  LARGE_INTEGER counter{};
  QueryPerformanceCounter(&counter);
  seed = kNormalSeed ^ static_cast<std::uint32_t>(GetTickCount64()) ^
    static_cast<std::uint32_t>(counter.QuadPart) ^ GetCurrentProcessId();
  return seed != 0 ? seed : kNormalSeed;
}

[[nodiscard]] bool ReducedMotionRequested() noexcept {
  BOOL animationsEnabled = TRUE;
  return SystemParametersInfoW(
    SPI_GETCLIENTAREAANIMATION, 0, &animationsEnabled, 0) != FALSE && animationsEnabled == FALSE;
}

[[nodiscard]] bool SameMessages(
    const MessagesDocument& left, const MessagesDocument& right) noexcept {
  return left.messages == right.messages && left.enabled == right.enabled &&
    left.frequencyMilliseconds == right.frequencyMilliseconds &&
    left.persistenceMilliseconds == right.persistenceMilliseconds &&
    left.appearMilliseconds == right.appearMilliseconds &&
    left.disappearMilliseconds == right.disappearMilliseconds &&
    left.flickerOut == right.flickerOut && left.brightnessFade == right.brightnessFade &&
    left.layout == right.layout && left.direction == right.direction &&
    left.position == right.position && left.jitter == right.jitter &&
    left.horizontalPosition == right.horizontalPosition &&
    left.horizontalJitter == right.horizontalJitter;
}

[[nodiscard]] bool SameImages(
    const ImagesDocument& left, const ImagesDocument& right) noexcept {
  if (left.enabled != right.enabled ||
      left.frequencyMilliseconds != right.frequencyMilliseconds ||
      left.persistenceMilliseconds != right.persistenceMilliseconds ||
      left.appearMilliseconds != right.appearMilliseconds ||
      left.disappearMilliseconds != right.disappearMilliseconds ||
      left.flickerOut != right.flickerOut || left.brightnessFade != right.brightnessFade ||
      left.imageScale != right.imageScale || left.placementJitter != right.placementJitter ||
      left.images.size() != right.images.size()) return false;
  for (std::size_t index = 0; index < left.images.size(); ++index) {
    const auto& a = left.images[index];
    const auto& b = right.images[index];
    if (a.name != b.name || a.width != b.width || a.height != b.height ||
        a.luminance != b.luminance) return false;
  }
  return true;
}

struct HostWindow;

class NativeHost final {
 public:
  NativeHost(HINSTANCE instance, HostOptions options)
      : instance_(instance), options_(options), settings_(store_.Load()),
        messageScheduler_(kNormalSeed ^ 0x4f1bbcdcu, [this](const std::string_view text) {
          return ResolveText(text);
        }), epochSeconds_(UnixSeconds()), imageEpochSeconds_(epochSeconds_),
        reducedMotion_(ReducedMotionRequested()) {}

  [[nodiscard]] int Run();
  LRESULT WindowMessage(HostWindow& host, HWND window, UINT message, WPARAM wParam, LPARAM lParam);

 private:
  [[nodiscard]] bool RegisterWindowClass();
  [[nodiscard]] bool CreateWindows();
  [[nodiscard]] bool AddWindow(const RECT& rectangle, DWORD style, DWORD extendedStyle, HWND parent);
  void RecalculateGeometry();
  void RebuildSimulations();
  void ResetRainToEmpty(double startSeconds);
  void WarmStaticRain();
  void BeginRampFromEmpty();
  void Tick();
  void RenderAll(double elapsedSeconds);
  void ApplyImageToBaseLayer(double nowSeconds);
  void InitializePresentation();
  void UpdateIntroPresentation();
  [[nodiscard]] bool SkipIntro();
  void PollSettingsFile();
  void UpdateMessages();
  [[nodiscard]] std::string ResolveText(std::string_view text) const;
  void Exit();
  void RelaunchMultiMonitor();
  void ToggleFullscreen(HostWindow& host);
  void ShowSettings(HWND owner);
  void ShowDocumentSettings(HWND owner, DocumentPage page);
  void ApplySettings(SettingsSnapshot settings);
  void SetModalState(HWND owner, bool open);
  void ToggleDocument(HWND owner, bool images);
  void ShowShortcutToast(bool images, bool enabled);
  void NudgeDensity(double factor);
  void RefreshReducedMotion();
  void ToggleUserPause();
  void ToggleHud(HostWindow& host);
  void SetTimelinePause(std::uint32_t reason, bool paused);
  void OnWindowDestroyed(HostWindow& host);
  [[nodiscard]] bool IsControlsWindow(const HostWindow& host) const noexcept;
  [[nodiscard]] bool IsSaver() const noexcept { return options_.mode == HostMode::ScreenSaver; }
  [[nodiscard]] bool IsMultiDisplay() const noexcept { return IsSaver() || options_.spanDisplays; }

  HINSTANCE instance_ = nullptr;
  HostOptions options_;
  std::uint32_t rainSeed_ = kNormalSeed;
  SettingsStoreWin32 store_;
  SettingsSnapshot settings_;
  std::vector<std::unique_ptr<HostWindow>> windows_;
  double virtualWidthDips_ = 0.0;
  double virtualHeightDips_ = 0.0;
  std::size_t columns_ = 0;
  std::size_t rows_ = 0;
  std::vector<RainLane> lanes_;
  std::vector<std::unique_ptr<RainSimulation>> simulations_;
  std::array<bool, kMaximumRainLanes> laneActive_{};
  std::vector<std::vector<std::uint8_t>> renderStates_;
  std::vector<std::vector<float>> renderBrightnessBoosts_;
  ImageScheduler imageScheduler_;
  MessageScheduler messageScheduler_;
  AdaptiveResolution adaptiveResolution_;
  LARGE_INTEGER frequency_{};
  LARGE_INTEGER previousCounter_{};
  double elapsedSeconds_ = 0.0;
  double epochSeconds_ = 0.0;
  double imageEpochSeconds_ = 0.0;
  std::uint32_t timelinePauseReasons_ = 0;
  double timelinePauseStartSeconds_ = 0.0;
  double renderScale_ = 1.0;
  double introStartSeconds_ = 0.0;
  double rainStartSeconds_ = 0.0;
  std::string introText_;
  float introOpacity_ = 0.0f;
  std::string shortcutToastText_;
  double shortcutToastStartSeconds_ = 0.0;
  bool presentationInitialized_ = false;
  bool introActive_ = false;
  bool staticFrameRendered_ = false;
  bool imagesConfigured_ = false;
  bool messagesConfigured_ = false;
  std::filesystem::file_time_type settingsWriteTime_{};
  bool settingsWriteKnown_ = false;
  double nextSettingsCheckSeconds_ = 0.0;
  bool exiting_ = false;
  bool cursorHidden_ = false;
  bool reducedMotion_ = false;
  bool userPaused_ = false;
  bool systemSuspended_ = false;
  bool visibilityPaused_ = false;
  double visibilityPauseStartSeconds_ = 0.0;
  double visibilityActualPauseStartSeconds_ = 0.0;
  double visibilityActualPausedSeconds_ = 0.0;
  bool modalOpen_ = false;
};

struct HostWindow {
  NativeHost* owner = nullptr;
  HWND handle = nullptr;
  RECT desktopRectangle{};
  LogicalDisplay logicalDisplay{};
  render::D3D11Renderer renderer;
  bool rendererReady = false;
  POINT initialCursor{};
  ULONGLONG createdTicks = 0;
  RECT restoredRectangle{};
  DWORD restoredStyle = 0;
  bool fullscreen = false;
  bool hudVisible = false;
  std::string hudText;
  double nextHudUpdateSeconds = 0.0;
  std::uint32_t hudBackingWidth = 0;
  std::uint32_t hudBackingHeight = 0;
  int clickCount = 0;
  ULONGLONG lastClickTicks = 0;
};

LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
  auto* host = reinterpret_cast<HostWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
    host = static_cast<HostWindow*>(create->lpCreateParams);
    host->handle = window;
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(host));
  }
  return host != nullptr
    ? host->owner->WindowMessage(*host, window, message, wParam, lParam)
    : DefWindowProcW(window, message, wParam, lParam);
}

BOOL CALLBACK MonitorCallback(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* rectangles = reinterpret_cast<std::vector<RECT>*>(data);
  MONITORINFO info{sizeof(info)};
  if (GetMonitorInfoW(monitor, &info) != FALSE) rectangles->push_back(info.rcMonitor);
  return TRUE;
}

bool NativeHost::RegisterWindowClass() {
  WNDCLASSEXW windowClass{sizeof(windowClass)};
  windowClass.style = CS_HREDRAW | CS_VREDRAW | CS_DBLCLKS | CS_OWNDC;
  windowClass.lpfnWndProc = WindowProcedure;
  windowClass.hInstance = instance_;
  windowClass.hIcon = LoadIconW(instance_, MAKEINTRESOURCEW(IDI_MATRIXCODE_ICON));
  windowClass.hIconSm = windowClass.hIcon;
  windowClass.hCursor = options_.mode == HostMode::ScreenSaver ? nullptr : LoadCursorW(nullptr, IDC_ARROW);
  windowClass.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  windowClass.lpszClassName = kWindowClass;
  return RegisterClassExW(&windowClass) != 0 || GetLastError() == ERROR_CLASS_ALREADY_EXISTS;
}

bool NativeHost::AddWindow(
    const RECT& rectangle, const DWORD style, const DWORD extendedStyle, const HWND parent) {
  auto host = std::make_unique<HostWindow>();
  host->owner = this;
  host->desktopRectangle = rectangle;
  host->createdTicks = GetTickCount64();
  host->hudVisible = LoadHudVisible();
  GetCursorPos(&host->initialCursor);
  const int width = static_cast<int>(std::max<LONG>(1, rectangle.right - rectangle.left));
  const int height = static_cast<int>(std::max<LONG>(1, rectangle.bottom - rectangle.top));
  HWND handle = CreateWindowExW(
    extendedStyle,
    kWindowClass,
    L"Matrix Code",
    style,
    rectangle.left,
    rectangle.top,
    width,
    height,
    parent,
    nullptr,
    instance_,
    host.get());
  if (handle == nullptr) return false;
  ShowWindow(handle, SW_SHOW);
  UpdateWindow(handle);
  host->rendererReady = host->renderer.Initialize(handle, options_.forceWarp);
  if (!host->rendererReady) {
    DestroyWindow(handle);
    return false;
  }
  windows_.push_back(std::move(host));
  return true;
}

bool NativeHost::CreateWindows() {
  if (options_.mode == HostMode::Preview) {
    if (options_.previewParent == nullptr || !IsWindow(options_.previewParent)) return false;
    RECT client{};
    GetClientRect(options_.previewParent, &client);
    return AddWindow(client, WS_CHILD | WS_VISIBLE, 0, options_.previewParent);
  }
  if (IsMultiDisplay()) {
    std::vector<RECT> monitors;
    if (EnumDisplayMonitors(
          nullptr, nullptr, MonitorCallback, reinterpret_cast<LPARAM>(&monitors)) == FALSE ||
        monitors.empty()) return false;
    for (const auto& monitor : monitors) {
      if (!AddWindow(
            monitor,
            WS_POPUP | WS_VISIBLE,
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
            nullptr)) return false;
    }
    for (const auto& window : windows_) SetWindowPos(
      window->handle, HWND_TOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    SetForegroundWindow(windows_.front()->handle);
    SetFocus(windows_.front()->handle);
    return !windows_.empty();
  }

  RECT rectangle{0, 0, 960, 600};
  AdjustWindowRectEx(&rectangle, WS_OVERLAPPEDWINDOW, FALSE, 0);
  const int width = rectangle.right - rectangle.left;
  const int height = rectangle.bottom - rectangle.top;
  rectangle.left = (GetSystemMetrics(SM_CXSCREEN) - width) / 2;
  rectangle.top = (GetSystemMetrics(SM_CYSCREEN) - height) / 2;
  rectangle.right = rectangle.left + width;
  rectangle.bottom = rectangle.top + height;
  return AddWindow(rectangle, WS_OVERLAPPEDWINDOW | WS_VISIBLE, 0, nullptr);
}

void NativeHost::RecalculateGeometry() {
  if (windows_.empty()) return;
  if ((options_.mode == HostMode::Standalone && !options_.spanDisplays) ||
      options_.mode == HostMode::Preview) {
    RECT client{};
    GetClientRect(windows_.front()->handle, &client);
    windows_.front()->desktopRectangle = client;
  }
  std::vector<PhysicalDisplay> physicalDisplays;
  physicalDisplays.reserve(windows_.size());
  for (const auto& window : windows_) {
    const UINT dpi = std::max(96u, GetDpiForWindow(window->handle));
    const double logicalPerPixel = 96.0 / static_cast<double>(dpi);
    physicalDisplays.push_back({
      static_cast<double>(window->desktopRectangle.left),
      static_cast<double>(window->desktopRectangle.top),
      static_cast<double>(window->desktopRectangle.right - window->desktopRectangle.left),
      static_cast<double>(window->desktopRectangle.bottom - window->desktopRectangle.top),
      logicalPerPixel,
      logicalPerPixel,
    });
  }
  const auto topology = SolveDisplayTopology(physicalDisplays);
  for (std::size_t index = 0; index < windows_.size(); ++index) {
    windows_[index]->logicalDisplay = topology.displays[index];
  }
  virtualWidthDips_ = topology.width;
  virtualHeightDips_ = topology.height;
  const double cellPixels = SimConfig{}.targetCellPixels * settings_.controls.glyphScale;
  const bool synchronizedVirtualGrid = IsMultiDisplay() && windows_.size() > 1;
  const double minimumGridDimension = synchronizedVirtualGrid ? 1.0 : 8.0;
  const auto gridDimension = [synchronizedVirtualGrid, minimumGridDimension, cellPixels](
      const double logicalPixels) {
    const double cells = synchronizedVirtualGrid
      ? std::ceil(logicalPixels / cellPixels)
      : std::round(logicalPixels / cellPixels);
    return static_cast<std::size_t>(std::max(minimumGridDimension, cells));
  };
  const auto nextColumns = gridDimension(virtualWidthDips_);
  const auto nextRows = gridDimension(virtualHeightDips_);
  if (nextColumns != columns_ || nextRows != rows_) {
    columns_ = nextColumns;
    rows_ = nextRows;
    if (simulations_.empty()) {
      RebuildSimulations();
    } else {
      for (auto& simulation : simulations_) simulation->Resize(columns_, rows_);
      for (auto& state : renderStates_) state.resize(columns_ * rows_ * 4);
      for (auto& boost : renderBrightnessBoosts_) boost.assign(columns_ * rows_, 0.0f);
      staticFrameRendered_ = false;
      adaptiveResolution_.Reset();
      renderScale_ = 1.0;
      if (reducedMotion_) WarmStaticRain();
    }
  }
}

void NativeHost::RebuildSimulations() {
  staticFrameRendered_ = false;
  const auto nextLanes = ComputeRainLanes(
    settings_.controls.density,
    settings_.controls.allowOverlap,
    TierLaneCap(settings_.controls.quality));
  const bool firstBuild = simulations_.empty();
  if (firstBuild) {
    adaptiveResolution_.Reset();
    renderScale_ = 1.0;
    simulations_.reserve(kMaximumRainLanes);
    renderStates_.reserve(kMaximumRainLanes);
    renderBrightnessBoosts_.reserve(kMaximumRainLanes);
    for (std::size_t index = 0; index < kMaximumRainLanes; ++index) {
      simulations_.push_back(std::make_unique<RainSimulation>(
        columns_, rows_, SeedForLane(rainSeed_, index), SimConfig{}, settings_.controls.glyphMode));
      renderStates_.emplace_back(columns_ * rows_ * 4);
      renderBrightnessBoosts_.emplace_back(columns_ * rows_, 0.0f);
    }
  } else {
    for (auto& simulation : simulations_) simulation->SetGlyphMode(settings_.controls.glyphMode);
  }

  std::array<bool, kMaximumRainLanes> activeNow{};
  for (const auto& lane : nextLanes) {
    if (lane.index >= simulations_.size()) continue;
    auto& simulation = simulations_[lane.index];
    if (!firstBuild && lane.index != 0 && !laneActive_[lane.index]) simulation->Reset();
    simulation->SetSpawnRateScale(lane.weight);
    activeNow[lane.index] = true;
    if (firstBuild) {
      Controls controls = settings_.controls;
      controls.density = lane.density;
      if (windows_.size() > 1) simulation->WarmUpDistributed(controls, 2.5, 1.0 / 60.0);
      else simulation->WarmUp(
        controls, options_.mode == HostMode::Preview ? 0.5 : 2.5, 1.0 / 60.0);
    }
  }
  lanes_ = nextLanes;
  laneActive_ = activeNow;

  const bool synchronizedVirtualGrid = IsMultiDisplay() && windows_.size() > 1;
  if (firstBuild && options_.mode != HostMode::Preview && !synchronizedVirtualGrid &&
      !reducedMotion_ &&
      settings_.controls.rampUpMilliseconds > 0.0) {
    for (auto& simulation : simulations_) {
      simulation->Reset();
      simulation->SetSpawnRateScale(0.0);
    }
    for (std::size_t index = 1; index < laneActive_.size(); ++index) laneActive_[index] = false;
  }
  if (!imagesConfigured_) {
    imageScheduler_.Configure(
      settings_.images, rainSeed_, imageEpochSeconds_, UnixSeconds(), windows_.size() > 1);
    imagesConfigured_ = true;
  }
  if (!messagesConfigured_) {
    messageScheduler_.Configure(settings_.messages);
    messagesConfigured_ = true;
  }
}

void NativeHost::ResetRainToEmpty(const double startSeconds) {
  for (auto& simulation : simulations_) {
    simulation->Reset();
    simulation->SetSpawnRateScale(0.0);
  }
  for (auto& state : renderStates_) std::fill(state.begin(), state.end(), std::uint8_t{0});
  for (auto& boost : renderBrightnessBoosts_) std::fill(boost.begin(), boost.end(), 0.0f);
  laneActive_.fill(false);
  if (!lanes_.empty() && lanes_.front().index < laneActive_.size()) {
    laneActive_[lanes_.front().index] = true;
  }
  rainStartSeconds_ = startSeconds;
  staticFrameRendered_ = false;
}

void NativeHost::WarmStaticRain() {
  if (simulations_.empty()) return;
  std::array<bool, kMaximumRainLanes> activeNow{};
  for (const auto& lane : lanes_) {
    if (lane.index >= simulations_.size()) continue;
    auto& simulation = simulations_[lane.index];
    if (lane.index != 0 && !laneActive_[lane.index]) simulation->Reset();
    Controls controls = settings_.controls;
    controls.density = lane.density;
    simulation->SetSpawnRateScale(lane.weight);
    if (windows_.size() > 1) simulation->WarmUpDistributed(controls, 2.5, 1.0 / 60.0);
    else simulation->WarmUp(
      controls, options_.mode == HostMode::Preview ? 0.5 : 2.5, 1.0 / 60.0);
    activeNow[lane.index] = true;
  }
  laneActive_ = activeNow;
  rainStartSeconds_ = -std::numeric_limits<double>::infinity();
  staticFrameRendered_ = false;
}

void NativeHost::BeginRampFromEmpty() {
  if (options_.mode != HostMode::Standalone || options_.spanDisplays || reducedMotion_ ||
      userPaused_ || settings_.controls.rampUpMilliseconds <= 0.0) return;
  const double start = introActive_ && !settings_.intro.rainDuringIntro
    ? std::numeric_limits<double>::infinity()
    : elapsedSeconds_;
  ResetRainToEmpty(start);
}

std::string NativeHost::ResolveText(const std::string_view text) const {
  TokenContext context;
  context.name = settings_.viewerName;
  context.nowMilliseconds = UnixSeconds() * 1000.0;
  context.countdownTargetMilliseconds = settings_.countdown.targetMilliseconds;
  for (const auto& moment : settings_.countdown.moments) {
    context.moments.insert_or_assign(moment.name, moment.targetMilliseconds);
  }
  context.runStartMilliseconds = epochSeconds_ * 1000.0;
  if (adaptiveResolution_.SmoothedMilliseconds() > 0.0) {
    context.framesPerSecond = 1000.0 / adaptiveResolution_.SmoothedMilliseconds();
  }
  return ResolveTokens(text, context);
}

void NativeHost::InitializePresentation() {
  presentationInitialized_ = true;
  introText_.clear();
  introOpacity_ = 0.0f;
  introStartSeconds_ = elapsedSeconds_;
  const bool synchronizedVirtualGrid = IsMultiDisplay() && windows_.size() > 1;
  introActive_ = options_.mode != HostMode::Preview && !synchronizedVirtualGrid &&
    !reducedMotion_ &&
    settings_.intro.enabled && !settings_.intro.lines.empty();
  if (synchronizedVirtualGrid) {
    rainStartSeconds_ = -std::numeric_limits<double>::infinity();
  } else if (introActive_ && !settings_.intro.rainDuringIntro) {
    // The initial simulation is deliberately pre-warmed for instant startup. After-mode intros
    // must clear that state even when ramp-up is zero, otherwise its decaying trails remain visible.
    ResetRainToEmpty(std::numeric_limits<double>::infinity());
  } else {
    rainStartSeconds_ = elapsedSeconds_;
  }
}

void NativeHost::UpdateIntroPresentation() {
  if (!presentationInitialized_) InitializePresentation();
  if (!introActive_) return;
  const double introElapsedMilliseconds = (elapsedSeconds_ - introStartSeconds_) * 1000.0;
  std::vector<IntroLine> resolvedLines = settings_.intro.lines;
  for (auto& line : resolvedLines) line.text = ResolveText(line.text);
  const auto state = ComputeIntroTimeline(
    resolvedLines,
    settings_.intro.charMilliseconds,
    settings_.intro.startDelayMilliseconds,
    settings_.intro.fadeOutMilliseconds,
    introElapsedMilliseconds);
  if (state.done) {
    introActive_ = false;
    introText_.clear();
    introOpacity_ = 0.0f;
    rainStartSeconds_ = RainStartAfterIntro(
      rainStartSeconds_, elapsedSeconds_, settings_.intro.rainDuringIntro,
      settings_.intro.postIntroDelayMilliseconds);
    return;
  }
  introText_ = state.visibleText;
  introText_ += IntroCursorVisible(introElapsedMilliseconds)
    ? "\xE2\x96\x88"
    : " ";
  introOpacity_ = static_cast<float>(state.opacity);
}

void NativeHost::UpdateMessages() {
  if (simulations_.empty() || reducedMotion_ || introActive_) return;
  RainSimulationMessageSink sink(*simulations_.front());
  std::vector<MessageRegion> regions;
  if (windows_.size() > 1 && settings_.controls.vignette > 0.0) {
    const double cellPixels = SimConfig{}.targetCellPixels * settings_.controls.glyphScale;
    regions.reserve(windows_.size());
    for (const auto& window : windows_) {
      regions.push_back({
        window->logicalDisplay.left / cellPixels,
        window->logicalDisplay.top / cellPixels,
        window->logicalDisplay.width / cellPixels,
        window->logicalDisplay.height / cellPixels,
      });
    }
  }
  messageScheduler_.Update(
    elapsedSeconds_ * 1000.0, sink,
    std::span<const MessageRegion>(regions.data(), regions.size()));
}

bool NativeHost::SkipIntro() {
  if (!introActive_) return false;
  introActive_ = false;
  introText_.clear();
  introOpacity_ = 0.0f;
  staticFrameRendered_ = false;
  rainStartSeconds_ = RainStartAfterIntro(
    rainStartSeconds_, elapsedSeconds_, settings_.intro.rainDuringIntro,
    settings_.intro.postIntroDelayMilliseconds);
  return true;
}

void NativeHost::PollSettingsFile() {
  const double pollClock = reducedMotion_ || userPaused_ ? UnixSeconds() : elapsedSeconds_;
  if (pollClock < nextSettingsCheckSeconds_) return;
  nextSettingsCheckSeconds_ = pollClock + 1.0;
  std::error_code error;
  const auto writeTime = std::filesystem::last_write_time(store_.FilePath(), error);
  if (error) return;
  if (!settingsWriteKnown_) {
    ApplySettings(store_.Load());
    return;
  }
  if (writeTime == settingsWriteTime_) return;
  ApplySettings(store_.Load());
}

void NativeHost::ApplyImageToBaseLayer(const double nowSeconds) {
  if (simulations_.empty()) return;
  const auto base = simulations_.front()->State();
  renderStates_.front().assign(base.begin(), base.end());
  std::fill(renderBrightnessBoosts_.front().begin(), renderBrightnessBoosts_.front().end(), 0.0f);
  const auto& active = imageScheduler_.Update(nowSeconds);
  const auto* mask = imageScheduler_.ActiveMask();
  if (!active.has_value() || mask == nullptr) return;
  const auto placement = ComputeImagePlacement(
    *mask, imageScheduler_.Document(), *active, columns_, rows_);
  if (placement.columns <= 0.0 || placement.rows <= 0.0) return;
  for (std::size_t row = 0; row < rows_; ++row) {
    for (std::size_t column = 0; column < columns_; ++column) {
      const double u = (static_cast<double>(column) + 0.5 - placement.originColumn) / placement.columns;
      const double v = (static_cast<double>(row) + 0.5 - placement.originRow) / placement.rows;
      if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) continue;
      const double luminance = SampleImageMask(*mask, u, v);
      const double feather = ImageEdgeFeather(u, v, placement.featherU, placement.featherV);
      const double falling = ImageFallingGate(
        static_cast<std::int32_t>(column), static_cast<std::int32_t>(row),
        active->rainElapsedSeconds, rainSeed_);
      const std::size_t index = row * columns_ + column;
      const std::size_t output = index * 4;
      const auto identity = Hash32(
        rainSeed_ ^ static_cast<std::uint32_t>(column) * 73856093u ^
        static_cast<std::uint32_t>(row) * 19349663u);
      const auto result = ApplyImageReveal(
        renderStates_.front()[output + 1] / 255.0,
        renderStates_.front()[output],
        settings_.controls.glyphMode,
        luminance,
        feather,
        falling,
        active->intensity,
        active->scramble,
        identity,
        active->animationBucket);
      if (result.influence <= 0.001) continue;
      if (result.glyph != renderStates_.front()[output]) {
        renderStates_.front()[output + 3] = renderStates_.front()[output];
        renderStates_.front()[output] = result.glyph;
        renderStates_.front()[output + 2] = static_cast<std::uint8_t>(
          (renderStates_.front()[output + 2] & (kFlagIsHead | kFlagWhiteHead)) | kPhaseMask);
      }
      renderStates_.front()[output + 1] = static_cast<std::uint8_t>(
        std::floor(std::clamp(result.brightness, 0.0, 1.0) * 255.0 + 0.5));
      renderBrightnessBoosts_.front()[index] = static_cast<float>(
        std::max(0.0, result.brightness - 1.0));
    }
  }
}

void NativeHost::RenderAll(const double elapsedSeconds) {
  const double now = timelinePauseReasons_ != 0 && timelinePauseStartSeconds_ > 0.0
    ? timelinePauseStartSeconds_
    : UnixSeconds();
  if (reducedMotion_) {
    const auto base = simulations_.front()->State();
    renderStates_.front().assign(base.begin(), base.end());
    std::fill(
      renderBrightnessBoosts_.front().begin(), renderBrightnessBoosts_.front().end(), 0.0f);
  } else {
    ApplyImageToBaseLayer(now);
  }
  float toastOpacity = 0.0f;
  float toastOffsetDips = -8.0f;
  if (!shortcutToastText_.empty() && shortcutToastStartSeconds_ > 0.0) {
    const double age = std::max(0.0, UnixSeconds() - shortcutToastStartSeconds_);
    if (reducedMotion_) {
      toastOpacity = age < 1.7 ? 1.0f : 0.0f;
    } else if (age < 1.88) {
      const double linear = age < 0.18
        ? age / 0.18
        : age <= 1.7 ? 1.0 : 1.0 - (age - 1.7) / 0.18;
      const double eased = std::clamp(linear, 0.0, 1.0);
      toastOpacity = static_cast<float>(eased * eased * (3.0 - 2.0 * eased));
    }
    toastOffsetDips = -8.0f * (1.0f - toastOpacity);
  }
  for (const auto& lane : lanes_) {
    if (lane.index == 0 || lane.index >= simulations_.size()) continue;
    const auto state = simulations_[lane.index]->State();
    renderStates_[lane.index].assign(state.begin(), state.end());
  }
  std::vector<render::RainLayerView> views;
  views.reserve(lanes_.size());
  for (const auto& lane : lanes_) {
    if (lane.index >= simulations_.size()) continue;
    views.push_back({
      renderStates_[lane.index],
      renderBrightnessBoosts_[lane.index],
      static_cast<std::uint32_t>(columns_),
      static_cast<std::uint32_t>(rows_),
      static_cast<float>(lane.offsetCells),
      1.0f,
    });
  }
  for (auto& window : windows_) {
    if (!IsWindowVisible(window->handle) || IsIconic(window->handle)) continue;
    if (!window->rendererReady) {
      window->renderer = render::D3D11Renderer{};
      window->rendererReady = window->renderer.Initialize(window->handle, true);
      if (!window->rendererReady) continue;
    }
    render::FrameParameters parameters;
    parameters.controls = settings_.controls;
    parameters.palette = PaletteForControls(settings_.controls);
    parameters.overlayText = introText_;
    parameters.toastText = shortcutToastText_;
    parameters.toastOpacity = toastOpacity;
    parameters.toastOffsetDips = toastOffsetDips;
    if (window->hudVisible && options_.mode == HostMode::Standalone) {
      RECT client{};
      GetClientRect(window->handle, &client);
      const auto outputWidth = static_cast<std::uint32_t>(std::max<LONG>(
        1, client.right - client.left));
      const auto outputHeight = static_cast<std::uint32_t>(std::max<LONG>(
        1, client.bottom - client.top));
      const auto backingWidth = std::max(1u, static_cast<std::uint32_t>(
        std::floor(static_cast<double>(outputWidth) * renderScale_)));
      const auto backingHeight = std::max(1u, static_cast<std::uint32_t>(
        std::floor(static_cast<double>(outputHeight) * renderScale_)));
      if (window->hudText.empty() || now >= window->nextHudUpdateSeconds ||
          backingWidth != window->hudBackingWidth || backingHeight != window->hudBackingHeight) {
        const double smoothed = adaptiveResolution_.SmoothedMilliseconds();
        const double fps = smoothed > 0.0 ? 1000.0 / smoothed : 0.0;
        std::ostringstream hud;
        hud << std::fixed << std::setprecision(0) << fps << " fps \xC2\xB7 "
            << std::lround(renderScale_ * 100.0) << "% res \xC2\xB7 "
            << backingWidth << "\xC3\x97" << backingHeight;
        window->hudText = hud.str();
        window->nextHudUpdateSeconds = now + 0.25;
        window->hudBackingWidth = backingWidth;
        window->hudBackingHeight = backingHeight;
      }
      parameters.hudText = window->hudText;
    }
    parameters.cellPixels = static_cast<float>(SimConfig{}.targetCellPixels * settings_.controls.glyphScale);
    parameters.virtualOriginX = static_cast<float>(window->logicalDisplay.left);
    parameters.virtualOriginY = static_cast<float>(window->logicalDisplay.top);
    parameters.logicalPerPixelX = static_cast<float>(window->logicalDisplay.logicalPerPixelX);
    parameters.logicalPerPixelY = static_cast<float>(window->logicalDisplay.logicalPerPixelY);
    parameters.adaptiveScale = static_cast<float>(renderScale_);
    parameters.elapsedSeconds = static_cast<float>(elapsedSeconds);
    parameters.overlayOpacity = introOpacity_;
    parameters.presentationMode = PresentationModeForWindowCount(windows_.size());
    if (!window->renderer.Render(views, parameters)) {
      window->renderer = render::D3D11Renderer{};
      window->rendererReady = window->renderer.Initialize(window->handle, true);
    }
  }
}

void NativeHost::Tick() {
  LARGE_INTEGER counter{};
  QueryPerformanceCounter(&counter);
  const double frameElapsed = static_cast<double>(counter.QuadPart - previousCounter_.QuadPart) /
    static_cast<double>(frequency_.QuadPart);
  previousCounter_ = counter;
  const bool frozen = reducedMotion_ || userPaused_;
  if (!frozen) elapsedSeconds_ += std::max(0.0, frameElapsed);
  RecalculateGeometry();
  PollSettingsFile();
  if (!shortcutToastText_.empty() && shortcutToastStartSeconds_ > 0.0) {
    const double lifetime = reducedMotion_ ? 1.7 : 1.88;
    if (UnixSeconds() - shortcutToastStartSeconds_ >= lifetime) {
      shortcutToastText_.clear();
      shortcutToastStartSeconds_ = 0.0;
      staticFrameRendered_ = false;
    }
  }
  const bool toastAnimating = !reducedMotion_ && !shortcutToastText_.empty();
  if (frozen && staticFrameRendered_ && !toastAnimating) return;
  if (simulations_.empty()) return;
  UpdateIntroPresentation();
  const bool rainStarted = elapsedSeconds_ >= rainStartSeconds_;
  if (rainStarted) UpdateMessages();
  const double rampDuration = options_.mode == HostMode::Preview ||
      (IsMultiDisplay() && windows_.size() > 1)
    ? 0.0
    : settings_.controls.rampUpMilliseconds / 1000.0;
  const double progress = rampDuration <= 0.0
    ? (elapsedSeconds_ >= rainStartSeconds_ ? 1.0 : 0.0)
    : std::clamp((elapsedSeconds_ - rainStartSeconds_) / rampDuration, 0.0, 1.0);
  const double easedRamp = RainRampEase(progress);
  const auto plan = frozen ? SimulationStepPlan{} : PlanSimulationSteps(frameElapsed);
  if (rainStarted) {
    for (const auto& lane : lanes_) {
      if (lane.index != 0 && !laneActive_[lane.index]) {
        simulations_[lane.index]->Reset();
        laneActive_[lane.index] = true;
      }
    }
    for (std::size_t step = 0; step < plan.steps; ++step) {
      for (const auto& lane : lanes_) {
        Controls controls = settings_.controls;
        controls.density = lane.density;
        simulations_[lane.index]->SetSpawnRateScale(lane.weight * easedRamp);
        simulations_[lane.index]->Update(plan.deltaSeconds, controls);
      }
    }
  }
  if (reducedMotion_) renderScale_ = 1.0;
  else if (!userPaused_) {
    renderScale_ = adaptiveResolution_.Update(
      std::clamp(frameElapsed, 0.001, 0.25) * 1000.0);
  }
  RenderAll(elapsedSeconds_);
  if (frozen) staticFrameRendered_ = true;
}

void NativeHost::Exit() {
  if (exiting_) return;
  exiting_ = true;
  for (const auto& window : windows_) {
    if (IsWindow(window->handle)) PostMessageW(window->handle, WM_CLOSE, 0, 0);
  }
}

void NativeHost::RelaunchMultiMonitor() {
  if (options_.mode != HostMode::Standalone || options_.spanDisplays) return;
  std::array<wchar_t, 32768> executable{};
  const DWORD length = GetModuleFileNameW(nullptr, executable.data(),
    static_cast<DWORD>(executable.size()));
  if (length == 0 || static_cast<std::size_t>(length) >= executable.size()) return;
  std::wstring command = L"\"";
  command.append(executable.data(), length);
  command += L"\" --multi-monitor";
  STARTUPINFOW startup{sizeof(startup)};
  PROCESS_INFORMATION process{};
  if (CreateProcessW(
        executable.data(), command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr,
        &startup, &process) != FALSE) {
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    Exit();
  }
}

void NativeHost::ToggleFullscreen(HostWindow& host) {
  if (options_.mode != HostMode::Standalone || options_.spanDisplays) return;
  if (!host.fullscreen) {
    host.restoredStyle = static_cast<DWORD>(GetWindowLongPtrW(host.handle, GWL_STYLE));
    GetWindowRect(host.handle, &host.restoredRectangle);
    MONITORINFO info{sizeof(info)};
    GetMonitorInfoW(MonitorFromWindow(host.handle, MONITOR_DEFAULTTONEAREST), &info);
    SetWindowLongPtrW(host.handle, GWL_STYLE, host.restoredStyle & ~WS_OVERLAPPEDWINDOW);
    SetWindowPos(host.handle, HWND_TOP,
      info.rcMonitor.left, info.rcMonitor.top,
      info.rcMonitor.right - info.rcMonitor.left,
      info.rcMonitor.bottom - info.rcMonitor.top,
      SWP_FRAMECHANGED | SWP_SHOWWINDOW);
    host.fullscreen = true;
  } else {
    SetWindowLongPtrW(host.handle, GWL_STYLE, host.restoredStyle);
    SetWindowPos(host.handle, nullptr,
      host.restoredRectangle.left, host.restoredRectangle.top,
      host.restoredRectangle.right - host.restoredRectangle.left,
      host.restoredRectangle.bottom - host.restoredRectangle.top,
      SWP_FRAMECHANGED | SWP_NOZORDER | SWP_SHOWWINDOW);
    host.fullscreen = false;
  }
}

void NativeHost::ShowSettings(HWND owner) {
  if (options_.mode != HostMode::Standalone || modalOpen_) return;
  SetModalState(owner, true);
  const INT_PTR result = SettingsWindow::ShowModal(owner, store_);
  SetModalState(owner, false);
  if (result == IDOK) ApplySettings(store_.Load());
}

void NativeHost::ApplySettings(SettingsSnapshot settings) {
  const bool simulationStructureChanged =
    settings.controls.density != settings_.controls.density ||
    settings.controls.glyphMode != settings_.controls.glyphMode ||
    settings.controls.allowOverlap != settings_.controls.allowOverlap ||
    settings.controls.quality != settings_.controls.quality;
  const bool imagesChanged = !SameImages(settings.images, settings_.images);
  const bool messagesChanged = !SameMessages(settings.messages, settings_.messages);
  const bool rampChanged =
    settings.controls.rampUpMilliseconds != settings_.controls.rampUpMilliseconds;
  staticFrameRendered_ = false;
  settings_ = std::move(settings);
  if (imagesChanged || !imagesConfigured_) {
    imageScheduler_.Configure(
      settings_.images, rainSeed_, imageEpochSeconds_, UnixSeconds(), windows_.size() > 1);
    imagesConfigured_ = true;
  }
  if (messagesChanged || !messagesConfigured_) {
    messageScheduler_.Configure(settings_.messages);
    messagesConfigured_ = true;
  }
  RecalculateGeometry();
  if (simulationStructureChanged) RebuildSimulations();
  if (reducedMotion_ && simulationStructureChanged) WarmStaticRain();
  else if (rampChanged) BeginRampFromEmpty();
  std::error_code error;
  settingsWriteTime_ = std::filesystem::last_write_time(store_.FilePath(), error);
  settingsWriteKnown_ = !error;
}

void NativeHost::SetModalState(const HWND owner, const bool open) {
  SetTimelinePause(kPauseModal, open);
  modalOpen_ = open;
  for (const auto& window : windows_) {
    if (window->handle != nullptr && window->handle != owner && IsWindow(window->handle)) {
      EnableWindow(window->handle, open ? FALSE : TRUE);
    }
  }
  if (!open && owner != nullptr && IsWindow(owner)) {
    SetForegroundWindow(owner);
    SetFocus(owner);
  }
}

void NativeHost::ShowDocumentSettings(const HWND owner, const DocumentPage page) {
  if (options_.mode != HostMode::Standalone || modalOpen_) return;
  SetModalState(owner, true);
  auto draft = settings_;
  bool saved = false;
  if (DocumentEditor::ShowModal(owner, draft, page) == IDOK) {
    std::wstring diagnostic;
    saved = store_.Save(draft, &diagnostic);
    if (!saved) {
      MessageBoxW(owner, diagnostic.c_str(), L"Matrix Code", MB_OK | MB_ICONERROR);
    }
  }
  SetModalState(owner, false);
  if (saved) ApplySettings(std::move(draft));
}

void NativeHost::ToggleDocument(const HWND owner, const bool images) {
  if (options_.mode != HostMode::Standalone) return;
  auto draft = settings_;
  if (images) draft.images.enabled = !draft.images.enabled;
  else draft.messages.enabled = !draft.messages.enabled;
  const bool enabled = images ? draft.images.enabled : draft.messages.enabled;
  std::wstring diagnostic;
  if (!store_.Save(draft, &diagnostic)) {
    MessageBoxW(owner, diagnostic.c_str(), L"Matrix Code", MB_OK | MB_ICONERROR);
    return;
  }
  ApplySettings(std::move(draft));
  ShowShortcutToast(images, enabled);
}

void NativeHost::ShowShortcutToast(const bool images, const bool enabled) {
  shortcutToastText_ = images ? "IMAGES " : "MESSAGES ";
  shortcutToastText_ += enabled ? "ENABLED" : "DISABLED";
  shortcutToastStartSeconds_ = UnixSeconds();
  staticFrameRendered_ = false;
}

void NativeHost::NudgeDensity(const double factor) {
  if (options_.mode != HostMode::Standalone) return;
  auto draft = settings_;
  draft.controls.density = std::clamp(draft.controls.density * factor, 0.1, 100.0);
  if (store_.Save(draft)) ApplySettings(std::move(draft));
}

void NativeHost::SetTimelinePause(const std::uint32_t reason, const bool paused) {
  const bool wasPaused = timelinePauseReasons_ != 0;
  if (paused) timelinePauseReasons_ |= reason;
  else timelinePauseReasons_ &= ~reason;
  const bool isPaused = timelinePauseReasons_ != 0;
  if (!wasPaused && isPaused) {
    const double nowSeconds = UnixSeconds();
    timelinePauseStartSeconds_ = nowSeconds;
    if (visibilityPaused_ && visibilityActualPauseStartSeconds_ <= 0.0) {
      visibilityActualPauseStartSeconds_ = nowSeconds;
    }
    return;
  }
  if (!wasPaused || isPaused) return;
  const double nowSeconds = UnixSeconds();
  if (visibilityPaused_ && visibilityActualPauseStartSeconds_ > 0.0) {
    visibilityActualPausedSeconds_ += std::max(
      0.0, nowSeconds - visibilityActualPauseStartSeconds_);
    visibilityActualPauseStartSeconds_ = 0.0;
  }
  const double pausedSeconds = timelinePauseStartSeconds_ > 0.0
    ? std::max(0.0, nowSeconds - timelinePauseStartSeconds_)
    : 0.0;
  timelinePauseStartSeconds_ = 0.0;
  epochSeconds_ += pausedSeconds;
  if (windows_.size() <= 1) {
    imageEpochSeconds_ += pausedSeconds;
    imageScheduler_.ShiftTimelineBy(pausedSeconds);
  }
  QueryPerformanceCounter(&previousCounter_);
  adaptiveResolution_.Reset();
  renderScale_ = 1.0;
  staticFrameRendered_ = false;
  nextSettingsCheckSeconds_ = 0.0;
}

void NativeHost::ToggleUserPause() {
  if (options_.mode != HostMode::Standalone || options_.spanDisplays || reducedMotion_) return;
  userPaused_ = !userPaused_;
  if (userPaused_) {
    SetTimelinePause(kPauseUser, true);
    staticFrameRendered_ = false;
    return;
  }
  SetTimelinePause(kPauseUser, false);
}

void NativeHost::ToggleHud(HostWindow& host) {
  if (options_.mode != HostMode::Standalone) return;
  host.hudVisible = !host.hudVisible;
  SaveHudVisible(host.hudVisible);
  staticFrameRendered_ = false;
}

bool NativeHost::IsControlsWindow(const HostWindow& host) const noexcept {
  if (!(IsMultiDisplay() && windows_.size() > 1)) return true;
  double minimumLeft = windows_.front()->logicalDisplay.left;
  double minimumTop = windows_.front()->logicalDisplay.top;
  double maximumRight = minimumLeft + windows_.front()->logicalDisplay.width;
  double maximumBottom = minimumTop + windows_.front()->logicalDisplay.height;
  for (const auto& candidate : windows_) {
    minimumLeft = std::min(minimumLeft, candidate->logicalDisplay.left);
    minimumTop = std::min(minimumTop, candidate->logicalDisplay.top);
    maximumRight = std::max(
      maximumRight, candidate->logicalDisplay.left + candidate->logicalDisplay.width);
    maximumBottom = std::max(
      maximumBottom, candidate->logicalDisplay.top + candidate->logicalDisplay.height);
  }
  const double centerX = (minimumLeft + maximumRight) * 0.5;
  const double centerY = (minimumTop + maximumBottom) * 0.5;
  const HostWindow* best = windows_.front().get();
  double bestDistance = std::numeric_limits<double>::infinity();
  for (const auto& candidate : windows_) {
    const double candidateX = candidate->logicalDisplay.left +
      candidate->logicalDisplay.width * 0.5;
    const double candidateY = candidate->logicalDisplay.top +
      candidate->logicalDisplay.height * 0.5;
    const double dx = candidateX - centerX;
    const double dy = candidateY - centerY;
    const double distance = dx * dx + dy * dy;
    if (distance < bestDistance) {
      best = candidate.get();
      bestDistance = distance;
    }
  }
  return best == &host;
}

void NativeHost::RefreshReducedMotion() {
  const bool requested = ReducedMotionRequested();
  if (requested == reducedMotion_) return;
  if (requested) {
    reducedMotion_ = true;
    SetTimelinePause(kPauseReducedMotion, true);
    presentationInitialized_ = true;
    introActive_ = false;
    introText_.clear();
    introOpacity_ = 0.0f;
    rainStartSeconds_ = -std::numeric_limits<double>::infinity();
    WarmStaticRain();
  } else {
    reducedMotion_ = false;
    SetTimelinePause(kPauseReducedMotion, false);
  }
  QueryPerformanceCounter(&previousCounter_);
  adaptiveResolution_.Reset();
  renderScale_ = 1.0;
  staticFrameRendered_ = false;
  nextSettingsCheckSeconds_ = 0.0;
}

void NativeHost::OnWindowDestroyed(HostWindow& host) {
  host.rendererReady = false;
  const bool any = std::any_of(windows_.begin(), windows_.end(), [](const auto& candidate) {
    return candidate->handle != nullptr && IsWindow(candidate->handle);
  });
  if (!any) PostQuitMessage(0);
}

LRESULT NativeHost::WindowMessage(
    HostWindow& host, HWND window, const UINT message, const WPARAM wParam, const LPARAM lParam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_SIZE:
      staticFrameRendered_ = false;
      if (host.rendererReady && wParam != SIZE_MINIMIZED) {
        const auto width = static_cast<std::uint32_t>(LOWORD(lParam));
        const auto height = static_cast<std::uint32_t>(HIWORD(lParam));
        if (width != 0 && height != 0 && !host.renderer.Resize(width, height)) {
          host.renderer = render::D3D11Renderer{};
          host.rendererReady = host.renderer.Initialize(host.handle, true);
        }
      }
      return 0;
    case WM_DPICHANGED:
      staticFrameRendered_ = false;
      if (options_.mode == HostMode::Standalone) {
        const auto* suggested = reinterpret_cast<const RECT*>(lParam);
        SetWindowPos(window, nullptr, suggested->left, suggested->top,
          suggested->right - suggested->left, suggested->bottom - suggested->top,
          SWP_NOACTIVATE | SWP_NOZORDER);
      }
      return 0;
    case WM_DISPLAYCHANGE:
      if (IsMultiDisplay()) Exit();
      return 0;
    case WM_SETTINGCHANGE:
      RefreshReducedMotion();
      return 0;
    case WM_ACTIVATEAPP:
      if (IsSaver() && wParam == FALSE && GetTickCount64() - host.createdTicks > 300) Exit();
      return 0;
    case WM_KILLFOCUS:
      if (IsSaver() && GetTickCount64() - host.createdTicks > 300) {
        DWORD nextProcess = 0;
        if (reinterpret_cast<HWND>(wParam) != nullptr) {
          GetWindowThreadProcessId(reinterpret_cast<HWND>(wParam), &nextProcess);
        }
        if (nextProcess != GetCurrentProcessId()) Exit();
      }
      return 0;
    case WM_POWERBROADCAST:
      if (wParam == PBT_APMSUSPEND) {
        systemSuspended_ = true;
        SetTimelinePause(kPauseSystem, true);
        for (auto& candidate : windows_) candidate->renderer.Suspend();
      }
      else if (wParam == PBT_APMRESUMEAUTOMATIC || wParam == PBT_APMRESUMECRITICAL ||
               wParam == PBT_APMRESUMESUSPEND) {
        systemSuspended_ = false;
        SetTimelinePause(kPauseSystem, false);
        for (auto& candidate : windows_) candidate->renderer.Resume();
        QueryPerformanceCounter(&previousCounter_);
        staticFrameRendered_ = false;
      }
      return TRUE;
    case WM_SETCURSOR:
      if (IsSaver()) { SetCursor(nullptr); return TRUE; }
      break;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
      if (IsSaver()) { Exit(); return 0; }
      {
      const auto keyState = static_cast<ULONG_PTR>(lParam);
      const bool repeat = (keyState & (static_cast<ULONG_PTR>(1) << 30u)) != 0;
      const bool alt = (keyState & (static_cast<ULONG_PTR>(1) << 29u)) != 0 ||
        (GetKeyState(VK_MENU) & 0x8000) != 0;
      const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
      const bool control = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
      const bool windowsKey = (GetKeyState(VK_LWIN) & 0x8000) != 0 ||
        (GetKeyState(VK_RWIN) & 0x8000) != 0;
      const bool synchronizedVirtualGrid = options_.spanDisplays && windows_.size() > 1;
      if (wParam == VK_ESCAPE && options_.spanDisplays) { Exit(); return 0; }
      if (synchronizedVirtualGrid && !IsControlsWindow(host)) return 0;
      if (!repeat && alt && !control && !windowsKey && wParam == L'F') {
        ToggleHud(host);
        return 0;
      }
      if (synchronizedVirtualGrid) {
        if (wParam == L'H') { ShowSettings(window); return 0; }
        if (wParam == VK_OEM_MINUS || wParam == VK_SUBTRACT) {
          NudgeDensity(1.0 / 1.2);
          return 0;
        }
        if (wParam == VK_OEM_PLUS || wParam == VK_ADD) {
          NudgeDensity(1.2);
          return 0;
        }
        return 0;
      }
      if (wParam == VK_ESCAPE && SkipIntro()) return 0;
      if (wParam == L'H') { ShowSettings(window); return 0; }
      if ((!alt && wParam == L'F') || wParam == VK_F11) { ToggleFullscreen(host); return 0; }
      if (wParam == L'I') { ShowDocumentSettings(window, DocumentPage::Intro); return 0; }
      if (wParam == L'C') { ShowDocumentSettings(window, DocumentPage::Countdown); return 0; }
      if (wParam == L'M') {
        if (shift && !control && !alt && !windowsKey) {
          if (!repeat) ToggleDocument(window, false);
        }
        else ShowDocumentSettings(window, DocumentPage::Messages);
        return 0;
      }
      if (wParam == L'X') {
        if (shift && !control && !alt && !windowsKey) {
          if (!repeat) ToggleDocument(window, true);
        }
        else ShowDocumentSettings(window, DocumentPage::Images);
        return 0;
      }
      if (wParam == L'N') { ToggleDocument(window, false); return 0; }
      if (wParam == VK_OEM_MINUS || wParam == VK_SUBTRACT) {
        NudgeDensity(1.0 / 1.2);
        return 0;
      }
      if (wParam == VK_OEM_PLUS || wParam == VK_ADD) {
        NudgeDensity(1.2);
        return 0;
      }
      if (wParam == L'P') {
        if (!repeat) ToggleUserPause();
        return 0;
      }
      if (wParam == VK_ESCAPE && host.fullscreen) { ToggleFullscreen(host); return 0; }
      }
      break;
    case WM_LBUTTONDOWN:
      if (options_.mode == HostMode::Standalone && !options_.spanDisplays) {
        const ULONGLONG now = GetTickCount64();
        host.clickCount = now - host.lastClickTicks <= kMultiClickMilliseconds
          ? host.clickCount + 1 : 1;
        host.lastClickTicks = now;
        if (host.clickCount >= 3) {
          KillTimer(window, kSettledClickTimer);
          host.clickCount = 0;
          RelaunchMultiMonitor();
          return 0;
        }
      }
      [[fallthrough]];
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
#if defined(WM_POINTERDOWN)
    case WM_POINTERDOWN:
#endif
      if (IsSaver()) { Exit(); return 0; }
      if (SkipIntro()) return 0;
      break;
    case WM_LBUTTONDBLCLK:
      if (options_.mode == HostMode::Standalone) {
        host.clickCount = std::max(host.clickCount, 2);
        host.lastClickTicks = GetTickCount64();
        SetTimer(window, kSettledClickTimer, kMultiClickMilliseconds, nullptr);
        return 0;
      }
      break;
    case WM_TIMER:
      if (wParam == kSettledClickTimer) {
        KillTimer(window, kSettledClickTimer);
        if (host.clickCount == 2) ToggleFullscreen(host);
        host.clickCount = 0;
        return 0;
      }
      break;
    case WM_MOUSEMOVE:
      if (IsSaver() && GetTickCount64() - host.createdTicks > 300) {
        POINT current{};
        GetCursorPos(&current);
        if (std::abs(current.x - host.initialCursor.x) >= 4 ||
            std::abs(current.y - host.initialCursor.y) >= 4) {
          Exit();
        }
      }
      return 0;
    case WM_CLOSE:
      if (IsMultiDisplay() && !exiting_) { Exit(); return 0; }
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      host.handle = nullptr;
      OnWindowDestroyed(host);
      return 0;
  }
  return DefWindowProcW(window, message, wParam, lParam);
}

int NativeHost::Run() {
  if (IsMultiDisplay() && GetSystemMetrics(SM_CMONITORS) > 1) {
    rainSeed_ = RandomSessionSeed();
  }
  if (!RegisterWindowClass() || !CreateWindows()) return 2;
  RecalculateGeometry();
  std::error_code settingsTimeError;
  settingsWriteTime_ = std::filesystem::last_write_time(store_.FilePath(), settingsTimeError);
  settingsWriteKnown_ = !settingsTimeError;
  QueryPerformanceFrequency(&frequency_);
  QueryPerformanceCounter(&previousCounter_);
  if (reducedMotion_) SetTimelinePause(kPauseReducedMotion, true);
  if (IsSaver()) {
    while (ShowCursor(FALSE) >= 0) {}
    cursorHidden_ = true;
  }
  MSG message{};
  while (true) {
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE) != FALSE) {
      if (message.message == WM_QUIT) {
        if (cursorHidden_) while (ShowCursor(TRUE) < 0) {}
        return static_cast<int>(message.wParam);
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    }
    if (systemSuspended_) {
      QueryPerformanceCounter(&previousCounter_);
      MsgWaitForMultipleObjectsEx(
        0, nullptr, 100u, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
      continue;
    }
    const bool anyVisibleWindow = std::any_of(
      windows_.begin(), windows_.end(), [](const auto& window) {
        return window->handle != nullptr &&
          IsWindowVisible(window->handle) != FALSE && IsIconic(window->handle) == FALSE;
      });
    bool anyOcclusionCandidate = false;
    bool allVisibleWindowsOccluded = anyVisibleWindow;
    if (anyVisibleWindow) {
      for (const auto& window : windows_) {
        if (window->handle == nullptr || IsWindowVisible(window->handle) == FALSE ||
            IsIconic(window->handle) != FALSE) continue;
        if (!window->rendererReady || window->renderer.LastError() != DXGI_STATUS_OCCLUDED) {
          allVisibleWindowsOccluded = false;
          continue;
        }
        anyOcclusionCandidate = true;
        if (window->renderer.ProbeOcclusion() != DXGI_STATUS_OCCLUDED) {
          allVisibleWindowsOccluded = false;
        }
      }
    }
    const bool pauseRendering = !anyVisibleWindow ||
      (anyOcclusionCandidate && allVisibleWindowsOccluded);
    if (pauseRendering) {
      if (!visibilityPaused_) {
        visibilityPaused_ = true;
        visibilityPauseStartSeconds_ = UnixSeconds();
        visibilityActualPausedSeconds_ = 0.0;
        visibilityActualPauseStartSeconds_ = timelinePauseReasons_ != 0
          ? visibilityPauseStartSeconds_
          : 0.0;
      }
      QueryPerformanceCounter(&previousCounter_);
      MsgWaitForMultipleObjectsEx(
        0, nullptr, 100u, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
      continue;
    }
    if (visibilityPaused_) {
      const double nowSeconds = UnixSeconds();
      if (visibilityActualPauseStartSeconds_ > 0.0) {
        visibilityActualPausedSeconds_ += std::max(
          0.0, nowSeconds - visibilityActualPauseStartSeconds_);
      }
      const double hiddenSeconds = std::max(
        0.0, nowSeconds - visibilityPauseStartSeconds_ - visibilityActualPausedSeconds_);
      elapsedSeconds_ += hiddenSeconds;
      visibilityPaused_ = false;
      visibilityPauseStartSeconds_ = 0.0;
      visibilityActualPauseStartSeconds_ = 0.0;
      visibilityActualPausedSeconds_ = 0.0;
      QueryPerformanceCounter(&previousCounter_);
      adaptiveResolution_.Reset();
      renderScale_ = 1.0;
    }
    Tick();
    const bool toastAnimating = !reducedMotion_ && !shortcutToastText_.empty();
    DWORD waitMilliseconds = reducedMotion_ || userPaused_
      ? (toastAnimating ? 16u : 100u)
      : 0u;
    if (!reducedMotion_ && !userPaused_) {
      LARGE_INTEGER afterRender{};
      QueryPerformanceCounter(&afterRender);
      const double frameWorkSeconds =
        static_cast<double>(afterRender.QuadPart - previousCounter_.QuadPart) /
        static_cast<double>(frequency_.QuadPart);
      // Present(1) follows the monitor refresh rate. Without the same 60 Hz budget used by the
      // nonblocking multi-window path, a high-refresh single display can begin at 120/144 FPS and
      // then fall to 60 FPS as the rain fills in and rendering gets more expensive.
      waitMilliseconds = FramePacingWaitMilliseconds(frameWorkSeconds);
    }
    MsgWaitForMultipleObjectsEx(
      0, nullptr, waitMilliseconds, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
  }
}

}  // namespace

int RunWin32Host(HINSTANCE instance, const HostOptions& options) {
  return NativeHost(instance, options).Run();
}

void EnablePerMonitorV2DpiAwareness() noexcept {
  using SetContext = BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT);
  if (const HMODULE user32 = GetModuleHandleW(L"user32.dll"); user32 != nullptr) {
    if (const auto setContext = reinterpret_cast<SetContext>(
          GetProcAddress(user32, "SetProcessDpiAwarenessContext")); setContext != nullptr) {
      setContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
  }
}

}  // namespace matrixcode::platform
