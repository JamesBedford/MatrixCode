#include "matrixcode/app/MatrixCodeHost.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <utility>
#include <vector>

#include <QApplication>
#include <QCloseEvent>
#include <QCursor>
#include <QDate>
#include <QDateTime>
#include <QDebug>
#include <QElapsedTimer>
#include <QFileInfo>
#include <QFocusEvent>
#include <QGuiApplication>
#include <QIcon>
#include <QKeyEvent>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMessageBox>
#include <QMouseEvent>
#include <QOpenGLContext>
#include <QOpenGLWidget>
#include <QPalette>
#include <QProcess>
#include <QProcessEnvironment>
#include <QRandomGenerator>
#include <QScreen>
#include <QSettings>
#include <QStandardPaths>
#include <QSurfaceFormat>
#include <QStyleHints>
#include <QTimer>
#include <QVBoxLayout>
#include <QWindow>
#include <QWheelEvent>

#include "matrixcode/core/Controllers.h"
#include "matrixcode/core/HolidayResolver.h"
#include "matrixcode/core/ImageReveal.h"
#include "matrixcode/core/IntroTimeline.h"
#include "matrixcode/core/MessageScheduler.h"
#include "matrixcode/core/RainSimulation.h"
#include "matrixcode/core/Rng.h"
#include "matrixcode/core/Settings.h"
#include "matrixcode/core/TokenResolver.h"
#include "matrixcode/platform/CommandLine.h"
#include "matrixcode/platform/SettingsStoreLinux.h"
#include "matrixcode/platform/X11Window.h"
#include "matrixcode/render/OpenGLRenderer.h"
#include "matrixcode/ui/SettingsDialog.h"

namespace matrixcode::app {
namespace {

constexpr std::uint32_t kNormalSeed = 0x001a2b3cu;
constexpr std::uint32_t kMessageSeed = 0x5eed1eu;
constexpr std::uint32_t kCaptureWidth = 960;
constexpr std::uint32_t kCaptureHeight = 600;
constexpr int kSoftwareFallbackExitCode = 75;
constexpr int kMaximumRendererRecoveryAttempts = 1;
constexpr std::size_t kMaximumRainLanes = 8;
constexpr int kFrameMilliseconds = 16;
constexpr int kIdlePollMilliseconds = 250;
constexpr qint64 kMultiClickMilliseconds = 350;
constexpr auto kUiStateKey = "mx-ui-state";
constexpr auto kFpsOverlayField = "fpsOverlayVisible";

double UnixSeconds() {
  return static_cast<double>(QDateTime::currentMSecsSinceEpoch()) / 1000.0;
}

bool StartSoftwareFallback() {
  QStringList arguments = QCoreApplication::arguments();
  if (!arguments.isEmpty()) arguments.removeFirst();
  if (arguments.contains(QStringLiteral("--software"))) return false;
  arguments.push_back(QStringLiteral("--software"));
  QProcess process;
  process.setProgram(QCoreApplication::applicationFilePath());
  process.setArguments(arguments);
  process.setWorkingDirectory(QCoreApplication::applicationDirPath());
  return process.startDetached();
}

bool ToolkitReducedMotionRequested() {
  const auto environment = QProcessEnvironment::systemEnvironment();
  if (environment.value("QT_ENABLE_ANIMATIONS") == "0" ||
      environment.value("GTK_ENABLE_ANIMATIONS") == "0") return true;
  const QString settingsPath = QStandardPaths::locate(
    QStandardPaths::ConfigLocation, "gtk-3.0/settings.ini");
  if (!settingsPath.isEmpty()) {
    QSettings gtk(settingsPath, QSettings::IniFormat);
    if (!gtk.value("Settings/gtk-enable-animations", true).toBool()) return true;
  }
  return false;
}

class ReducedMotionMonitor final {
 public:
  ReducedMotionMonitor() {
    QProcess query;
    query.start(QStringLiteral("gsettings"), {
      QStringLiteral("get"), QStringLiteral("org.gnome.desktop.interface"),
      QStringLiteral("enable-animations")});
    if (query.waitForStarted(250)) {
      if (query.waitForFinished(500)) {
        ApplyGnomeValue(query.readAllStandardOutput());
      } else {
        query.kill();
        query.waitForFinished(250);
      }
    }

    QObject::connect(&monitor_, &QProcess::readyReadStandardOutput, &monitor_, [this] {
      ApplyGnomeValue(monitor_.readAllStandardOutput());
    });
    monitor_.start(QStringLiteral("gsettings"), {
      QStringLiteral("monitor"), QStringLiteral("org.gnome.desktop.interface"),
      QStringLiteral("enable-animations")});
  }

  ~ReducedMotionMonitor() {
    if (monitor_.state() == QProcess::NotRunning) return;
    monitor_.terminate();
    if (!monitor_.waitForFinished(250)) {
      monitor_.kill();
      monitor_.waitForFinished(250);
    }
  }

  [[nodiscard]] bool Requested() const {
    return ToolkitReducedMotionRequested() ||
      (gnomeAnimationsEnabled_.has_value() && !*gnomeAnimationsEnabled_);
  }

 private:
  void ApplyGnomeValue(const QByteArray& output) {
    const QList<QByteArray> lines = output.split('\n');
    for (auto line = lines.crbegin(); line != lines.crend(); ++line) {
      const QByteArray value = line->trimmed();
      if (value == "true" || value.endsWith(" true")) {
        gnomeAnimationsEnabled_ = true;
        return;
      }
      if (value == "false" || value.endsWith(" false")) {
        gnomeAnimationsEnabled_ = false;
        return;
      }
    }
  }

  QProcess monitor_;
  std::optional<bool> gnomeAnimationsEnabled_;
};

std::uint32_t RandomSessionSeed() {
  const std::uint32_t seed = QRandomGenerator::system()->generate();
  return seed != 0 ? seed : kNormalSeed;
}

bool LoadHudVisible() {
  QSettings state("MatrixCode", "MatrixCode");
  const QJsonDocument document = QJsonDocument::fromJson(
    state.value(kUiStateKey).toString().toUtf8());
  if (!document.isObject()) return false;
  const QJsonValue visible = document.object().value(kFpsOverlayField);
  return visible.isBool() && visible.toBool();
}

void SaveHudVisible(const bool visible) {
  QSettings state("MatrixCode", "MatrixCode");
  if (!visible) {
    state.remove(kUiStateKey);
    return;
  }
  const QJsonObject document{{kFpsOverlayField, true}};
  state.setValue(kUiStateKey, QString::fromUtf8(
    QJsonDocument(document).toJson(QJsonDocument::Compact)));
}

QString FromUtf8(const std::string& value) {
  return QString::fromUtf8(value.data(), static_cast<qsizetype>(value.size()));
}

bool SameMessages(const MessagesDocument& left, const MessagesDocument& right) {
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

bool SameImages(const ImagesDocument& left, const ImagesDocument& right) {
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

class MatrixCodeHost;

class RainContainer final : public QWidget {
 public:
  explicit RainContainer(MatrixCodeHost& host) : host_(host) {}

 protected:
  void closeEvent(QCloseEvent* event) override;

 private:
  MatrixCodeHost& host_;
};

class RainWidget final : public QOpenGLWidget {
 public:
  RainWidget(MatrixCodeHost& host, QWidget* parent);
  ~RainWidget() override;

  void SetVirtualGeometry(QRectF logicalDisplay);
  [[nodiscard]] const QRectF& VirtualGeometry() const noexcept { return logicalDisplay_; }
  [[nodiscard]] render::OpenGLRenderer& Renderer() noexcept { return renderer_; }
  [[nodiscard]] bool BeginRendererRecovery() noexcept {
    if (rendererRecoveryAttempts_ >= kMaximumRendererRecoveryAttempts) return false;
    ++rendererRecoveryAttempts_;
    return true;
  }
  void ResetRendererRecovery() noexcept { rendererRecoveryAttempts_ = 0; }

 protected:
  void initializeGL() override;
  void resizeGL(int width, int height) override;
  void paintGL() override;
  void keyPressEvent(QKeyEvent* event) override;
  void mousePressEvent(QMouseEvent* event) override;
  void mouseDoubleClickEvent(QMouseEvent* event) override;
  void mouseMoveEvent(QMouseEvent* event) override;
  void wheelEvent(QWheelEvent* event) override;
  bool event(QEvent* event) override;
  void closeEvent(QCloseEvent* event) override;
  void focusOutEvent(QFocusEvent* event) override;

 private:
  MatrixCodeHost& host_;
  render::OpenGLRenderer renderer_;
  QRectF logicalDisplay_;
  QMetaObject::Connection contextDestroyConnection_;
  int rendererRecoveryAttempts_ = 0;
};

struct RainWindow {
  QWidget* container = nullptr;
  RainWidget* rain = nullptr;
  QScreen* screen = nullptr;
  bool fullscreen = false;
  bool hudVisible = false;
  QString hudText;
  double nextHudUpdateSeconds = 0.0;
};

class MatrixCodeHost final : public QObject {
 public:
  MatrixCodeHost(QApplication& application, platform::CommandLineOptions options)
      : QObject(&application), application_(application), options_(std::move(options)),
        settings_(options_.mode == platform::LaunchMode::Capture ? DefaultSettings() : store_.Load()),
        embeddedWindowLifecycleMonitor_([this] { HandleEmbeddedWindowDestroyed(); }),
        rainSeed_(kNormalSeed),
        messageScheduler_(kMessageSeed, [this](const std::string_view text) {
          return ResolveText(text);
        }), epochSeconds_(UnixSeconds()), imageEpochSeconds_(epochSeconds_),
        reducedMotion_(reducedMotionMonitor_.Requested()) {
    frameClock_.start();
    previousNanoseconds_ = frameClock_.nsecsElapsed();
    timer_.setTimerType(Qt::PreciseTimer);
    timer_.setInterval(kFrameMilliseconds);
    QObject::connect(&timer_, &QTimer::timeout, this, [this] { Tick(); });
    QObject::connect(&application_, &QGuiApplication::applicationStateChanged,
      this, [this](const Qt::ApplicationState state) {
        if (!IsEmbedded()) SetPauseReason(kPauseInactive, state != Qt::ApplicationActive);
      });
    QObject::connect(&application_, &QGuiApplication::screenAdded,
      this, [this](QScreen*) { ScreensChanged(); });
    QObject::connect(&application_, &QGuiApplication::screenRemoved,
      this, [this](QScreen*) { ScreensChanged(); });
  }
  ~MatrixCodeHost() override;

  int Run();
  void Render(RainWidget& widget, render::OpenGLRenderer& renderer);
  void GeometryChanged();
  void HandleKey(RainWidget& widget, QKeyEvent& event);
  void HandleMousePress(RainWidget& widget, QMouseEvent& event);
  void HandleDoubleClick(RainWidget& widget, QMouseEvent& event);
  void HandleMouseMove(RainWidget& widget, QMouseEvent& event);
  void HandleWheel(QWheelEvent& event);
  void HandlePointerActivity(QEvent& event);
  void HandleRendererFailure(RainWidget& widget, const QString& diagnostic);
  void HandleClose(QCloseEvent& event);
  void HandleFocusOut();
  [[nodiscard]] bool IsCapture() const noexcept {
    return options_.mode == platform::LaunchMode::Capture;
  }

 private:
  enum PauseReason : std::uint32_t {
    kPauseUser = 1u << 0u,
    kPauseReducedMotion = 1u << 1u,
    kPauseModal = 1u << 2u,
    kPauseInactive = 1u << 3u,
    kPauseHidden = 1u << 4u,
  };

  [[nodiscard]] bool IsSaver() const noexcept {
    return options_.mode == platform::LaunchMode::ScreenSaver;
  }
  [[nodiscard]] bool IsStandaloneSaver() const noexcept {
    return IsSaver() && !options_.xscreensaverHosted;
  }
  [[nodiscard]] bool IsPreview() const noexcept {
    return options_.mode == platform::LaunchMode::Preview;
  }
  [[nodiscard]] bool IsEmbedded() const noexcept {
    return IsPreview() || options_.xscreensaverHosted;
  }
  [[nodiscard]] bool IsMultiDisplay() const noexcept {
    return options_.multiMonitor || (IsSaver() && !options_.xscreensaverHosted);
  }
  [[nodiscard]] bool Frozen() const noexcept {
    return reducedMotion_ || userPaused_ || (pauseReasons_ & ~(kPauseReducedMotion | kPauseUser)) != 0;
  }

  bool CreateWindows();
  RainWindow& AddWindow(QScreen* screen, bool fullscreen);
  [[nodiscard]] bool EmbedPreview(RainWindow& window);
  void RecalculateGeometry();
  void RebuildSimulations(bool preservePresentation = true);
  void ResetRainToEmpty(double startSeconds);
  void WarmStaticRain();
  void InitializePresentation();
  void UpdateIntroPresentation();
  void UpdateMessages();
  void ApplyImageToBaseLayer(double nowSeconds);
  void UpdateRenderBuffers();
  void Tick();
  void PollSettings();
  void RefreshSettingsStamp();
  void ApplySettings(SettingsSnapshot settings, bool preview = false);
  void OpenSettings(ui::SettingsPage page, QWidget* owner);
  void ToggleDocument(bool images);
  void NudgeDensity(double factor);
  void ToggleFullscreen(RainWidget& widget);
  void StartMultiMonitor();
  bool SkipIntro();
  void ShowToast(std::string text);
  void RefreshTimerCadence();
  void SetPauseReason(PauseReason reason, bool paused);
  void ShiftPresentationTimelines(double durationSeconds);
  [[nodiscard]] double PresentationTimeSeconds() const;
  [[nodiscard]] std::string ResolveText(std::string_view text) const;
  [[nodiscard]] Controls EffectiveControls() const;
  [[nodiscard]] RainWindow* WindowFor(RainWidget& widget);
  [[nodiscard]] RainWindow* ControlsWindow();
  void HandleEmbeddedWindowDestroyed();
  void ScreensChanged();
  void ExitAll();

  QApplication& application_;
  platform::CommandLineOptions options_;
  platform::SettingsStoreLinux store_;
  SettingsSnapshot settings_;
  std::vector<std::unique_ptr<RainWindow>> windows_;
  std::unique_ptr<QWindow> previewParent_;
  platform::X11WindowLifecycleMonitor embeddedWindowLifecycleMonitor_;
  bool embeddedWindowLifecycleMonitorInstalled_ = false;
  QTimer timer_;
  QElapsedTimer frameClock_;
  qint64 previousNanoseconds_ = 0;
  QFileInfo settingsFile_;
  QDateTime settingsModified_;
  bool settingsFileKnown_ = false;
  double nextSettingsPollSeconds_ = 0.0;
  std::uint32_t rainSeed_ = kNormalSeed;
  std::size_t columns_ = 0;
  std::size_t rows_ = 0;
  double virtualWidth_ = 0.0;
  double virtualHeight_ = 0.0;
  std::vector<RainLane> lanes_;
  std::vector<std::unique_ptr<RainSimulation>> simulations_;
  std::array<bool, kMaximumRainLanes> laneActive_{};
  std::vector<std::vector<std::uint8_t>> renderStates_;
  std::vector<std::vector<float>> renderBrightnessBoosts_;
  std::vector<render::RainLayerView> renderViews_;
  ImageScheduler imageScheduler_;
  MessageScheduler messageScheduler_;
  AdaptiveResolution adaptiveResolution_;
  double renderScale_ = 1.0;
  double elapsedSeconds_ = 0.0;
  double epochSeconds_ = 0.0;
  double imageEpochSeconds_ = 0.0;
  double rainStartSeconds_ = 0.0;
  double introStartSeconds_ = 0.0;
  std::string introText_;
  float introOpacity_ = 0.0f;
  bool presentationInitialized_ = false;
  bool introActive_ = false;
  bool messagesConfigured_ = false;
  bool imagesConfigured_ = false;
  std::uint32_t pauseReasons_ = 0;
  double pauseStartedSeconds_ = 0.0;
  ReducedMotionMonitor reducedMotionMonitor_;
  bool reducedMotion_ = false;
  bool userPaused_ = false;
  bool staticFrameRendered_ = false;
  bool settingsOpen_ = false;
  std::uint64_t settingsPreviewGeneration_ = 0;
  bool exiting_ = false;
  std::string toastText_;
  double toastStartSeconds_ = 0.0;
  qint64 lastClickMilliseconds_ = 0;
  int clickCount_ = 0;
  QPoint saverInitialCursor_;
  QElapsedTimer saverGrace_;
  bool captureSaved_ = false;
  bool saverCursorHidden_ = false;
  FullMoonDayCache fullMoonCache_;
  std::string renderedPreset_;
};

RainWidget::RainWidget(MatrixCodeHost& host, QWidget* parent)
    : QOpenGLWidget(parent), host_(host) {
  setFocusPolicy(Qt::StrongFocus);
  setMouseTracking(true);
  setAttribute(Qt::WA_AcceptTouchEvents);
  setAutoFillBackground(false);
  setAccessibleName(tr("Matrix Code animated digital rain"));
  setAccessibleDescription(tr("A continuous GPU-rendered field of stationary Matrix rain glyphs."));
  QSurfaceFormat format = QSurfaceFormat::defaultFormat();
  format.setSwapInterval(0);
  setFormat(format);
}

void RainContainer::closeEvent(QCloseEvent* event) {
  host_.HandleClose(*event);
  if (event->isAccepted()) QWidget::closeEvent(event);
}

RainWidget::~RainWidget() {
  QObject::disconnect(contextDestroyConnection_);
  if (context() != nullptr && context()->isValid()) {
    makeCurrent();
    renderer_.Cleanup();
    doneCurrent();
  }
}

void RainWidget::SetVirtualGeometry(QRectF logicalDisplay) {
  logicalDisplay_ = std::move(logicalDisplay);
}

void RainWidget::initializeGL() {
  QObject::disconnect(contextDestroyConnection_);
  contextDestroyConnection_ = QObject::connect(
    context(), &QOpenGLContext::aboutToBeDestroyed, this, [this] {
    makeCurrent();
    renderer_.Cleanup();
    doneCurrent();
  });
  if (!renderer_.Initialize(context())) {
    const QString diagnostic = FromUtf8(renderer_.Diagnostics().lastError);
    qCritical().noquote() << "Matrix Code OpenGL initialization failed:" << diagnostic;
    QTimer::singleShot(0, this, [this, diagnostic] {
      host_.HandleRendererFailure(*this, diagnostic);
    });
    return;
  }
  const qreal ratio = devicePixelRatioF();
  static_cast<void>(renderer_.Resize(
    host_.IsCapture() ? kCaptureWidth
                      : static_cast<std::uint32_t>(std::max(1, qRound(width() * ratio))),
    host_.IsCapture() ? kCaptureHeight
                      : static_cast<std::uint32_t>(std::max(1, qRound(height() * ratio)))));
}

void RainWidget::resizeGL(const int width, const int height) {
  const qreal ratio = devicePixelRatioF();
  static_cast<void>(renderer_.Resize(
    host_.IsCapture() ? kCaptureWidth
                      : static_cast<std::uint32_t>(std::max(1, qRound(width * ratio))),
    host_.IsCapture() ? kCaptureHeight
                      : static_cast<std::uint32_t>(std::max(1, qRound(height * ratio)))));
  host_.GeometryChanged();
}

void RainWidget::paintGL() {
  host_.Render(*this, renderer_);
}

void RainWidget::keyPressEvent(QKeyEvent* event) {
  host_.HandleKey(*this, *event);
  if (!event->isAccepted()) QOpenGLWidget::keyPressEvent(event);
}

void RainWidget::mousePressEvent(QMouseEvent* event) {
  host_.HandleMousePress(*this, *event);
  if (!event->isAccepted()) QOpenGLWidget::mousePressEvent(event);
}

void RainWidget::mouseDoubleClickEvent(QMouseEvent* event) {
  host_.HandleDoubleClick(*this, *event);
  if (!event->isAccepted()) QOpenGLWidget::mouseDoubleClickEvent(event);
}

void RainWidget::mouseMoveEvent(QMouseEvent* event) {
  host_.HandleMouseMove(*this, *event);
  if (!event->isAccepted()) QOpenGLWidget::mouseMoveEvent(event);
}

void RainWidget::wheelEvent(QWheelEvent* event) {
  host_.HandleWheel(*event);
  if (!event->isAccepted()) QOpenGLWidget::wheelEvent(event);
}

bool RainWidget::event(QEvent* event) {
  if (event->type() == QEvent::TouchBegin || event->type() == QEvent::TabletPress ||
      event->type() == QEvent::NativeGesture) {
    host_.HandlePointerActivity(*event);
    if (event->isAccepted()) return true;
  }
  return QOpenGLWidget::event(event);
}

void RainWidget::closeEvent(QCloseEvent* event) {
  host_.HandleClose(*event);
}

void RainWidget::focusOutEvent(QFocusEvent* event) {
  host_.HandleFocusOut();
  QOpenGLWidget::focusOutEvent(event);
}

MatrixCodeHost::~MatrixCodeHost() {
  timer_.stop();
  embeddedWindowLifecycleMonitor_.Stop();
  if (embeddedWindowLifecycleMonitorInstalled_) {
    application_.removeNativeEventFilter(&embeddedWindowLifecycleMonitor_);
    embeddedWindowLifecycleMonitorInstalled_ = false;
  }
  if (saverCursorHidden_) {
    application_.restoreOverrideCursor();
    saverCursorHidden_ = false;
  }
  for (auto& window : windows_) {
    delete window->container;
    window->container = nullptr;
    window->rain = nullptr;
  }
}

RainWindow& MatrixCodeHost::AddWindow(QScreen* screen, const bool fullscreen) {
  auto window = std::make_unique<RainWindow>();
  window->screen = screen;
  window->container = new RainContainer(*this);
  window->container->setWindowTitle(QObject::tr("Matrix Code"));
  window->container->setWindowIcon(QIcon(":/matrixcode/icons/matrixcode.svg"));
  QPalette palette = window->container->palette();
  palette.setColor(QPalette::Window, Qt::black);
  window->container->setPalette(palette);
  window->container->setAutoFillBackground(true);
  auto* layout = new QVBoxLayout(window->container);
  layout->setContentsMargins(0, 0, 0, 0);
  layout->setSpacing(0);
  window->rain = new RainWidget(*this, window->container);
  window->hudVisible = LoadHudVisible();
  layout->addWidget(window->rain);
  window->fullscreen = fullscreen;
  if (fullscreen) {
    window->container->setWindowFlags(
      Qt::Window | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint);
    if (screen != nullptr) {
      window->container->setGeometry(screen->geometry());
      window->container->winId();
      if (window->container->windowHandle() != nullptr) {
        window->container->windowHandle()->setScreen(screen);
      }
    }
    window->container->showFullScreen();
  } else {
    window->container->resize(960, 600);
    if (!IsEmbedded()) window->container->show();
  }
  if (!IsEmbedded()) window->rain->setFocus();
  windows_.push_back(std::move(window));
  return *windows_.back();
}

bool MatrixCodeHost::CreateWindows() {
  if (options_.mode == platform::LaunchMode::Settings) return true;
  if (IsEmbedded()) {
    RainWindow& window = AddWindow(QGuiApplication::primaryScreen(), false);
    return EmbedPreview(window);
  }
  const bool wall = IsMultiDisplay();
  if (wall) {
    const auto screens = QGuiApplication::screens();
    for (QScreen* screen : screens) AddWindow(screen, true);
  } else AddWindow(QGuiApplication::primaryScreen(), false);
  return !windows_.empty();
}

bool MatrixCodeHost::EmbedPreview(RainWindow& window) {
  if (options_.parentWindowId == 0 ||
      QGuiApplication::platformName() != QStringLiteral("xcb")) {
    qCritical() << "Matrix Code preview embedding requires a valid X11 host window";
    return false;
  }
  previewParent_.reset(QWindow::fromWinId(static_cast<WId>(options_.parentWindowId)));
  if (!previewParent_) {
    qCritical() << "Matrix Code could not open the X11 preview host window";
    return false;
  }
  const std::optional<QSize> hostSize = platform::QueryX11WindowSize(options_.parentWindowId);
  if (!hostSize.has_value()) {
    qCritical() << "Matrix Code could not read the X11 preview host geometry";
    return false;
  }
  window.container->setWindowFlags(Qt::FramelessWindowHint);
  window.container->winId();
  if (window.container->windowHandle() == nullptr) {
    qCritical() << "Matrix Code could not create its X11 preview child window";
    return false;
  }
  embeddedWindowLifecycleMonitor_.Watch(
    options_.parentWindowId, static_cast<quint64>(window.container->winId()));
  application_.installNativeEventFilter(&embeddedWindowLifecycleMonitor_);
  embeddedWindowLifecycleMonitorInstalled_ = true;
  window.container->windowHandle()->setParent(previewParent_.get());
  const qreal pixelRatio = std::max(0.001, window.container->devicePixelRatioF());
  window.container->setGeometry(
    0, 0,
    std::max(1, qRound(hostSize->width() / pixelRatio)),
    std::max(1, qRound(hostSize->height() / pixelRatio)));
  window.container->show();
  return true;
}

int MatrixCodeHost::Run() {
  if (options_.mode == platform::LaunchMode::Settings) {
    ui::SettingsDialog dialog(settings_);
    if (dialog.exec() != QDialog::Accepted) return 0;
    QString diagnostic;
    if (!store_.Save(dialog.Result(), &diagnostic)) {
      QMessageBox::critical(nullptr, QObject::tr("Matrix Code"), diagnostic);
      return 1;
    }
    return 0;
  }
  if (IsMultiDisplay() && QGuiApplication::screens().size() > 1) {
    rainSeed_ = RandomSessionSeed();
  }
  if (!CreateWindows()) return 2;
  saverInitialCursor_ = QCursor::pos();
  saverGrace_.start();
  if (IsStandaloneSaver()) {
    application_.setOverrideCursor(Qt::BlankCursor);
    saverCursorHidden_ = true;
  }
  RecalculateGeometry();
  if (!IsEmbedded()) {
    RainWindow* controls = ControlsWindow();
    if (controls != nullptr) {
      controls->container->raise();
      controls->container->activateWindow();
      controls->rain->setFocus();
    }
  }
  RebuildSimulations(false);
  InitializePresentation();
  if (options_.mode == platform::LaunchMode::Capture) WarmStaticRain();
  settingsFile_.setFile(store_.FilePath());
  settingsFileKnown_ = settingsFile_.exists();
  settingsModified_ = settingsFileKnown_ ? settingsFile_.lastModified() : QDateTime{};
  if (reducedMotion_) {
    pauseReasons_ |= kPauseReducedMotion;
    WarmStaticRain();
  }
  if (!IsEmbedded()) {
    SetPauseReason(kPauseInactive, application_.applicationState() != Qt::ApplicationActive);
  }
  timer_.start();
  return application_.exec();
}

void MatrixCodeHost::RecalculateGeometry() {
  if (windows_.empty()) return;
  QRectF bounds;
  bool first = true;
  for (const auto& window : windows_) {
    QRectF geometry;
    if (IsMultiDisplay() && window->screen != nullptr) geometry = window->screen->geometry();
    else geometry = QRectF(0.0, 0.0, window->rain->width(), window->rain->height());
    if (first) { bounds = geometry; first = false; }
    else bounds = bounds.united(geometry);
  }
  for (const auto& window : windows_) {
    QRectF geometry;
    if (IsMultiDisplay() && window->screen != nullptr) geometry = window->screen->geometry();
    else geometry = QRectF(0.0, 0.0, window->rain->width(), window->rain->height());
    geometry.translate(-bounds.left(), -bounds.top());
    window->rain->SetVirtualGeometry(geometry);
  }
  virtualWidth_ = std::max(1.0, bounds.width());
  virtualHeight_ = std::max(1.0, bounds.height());
  const double cellPixels = SimConfig{}.targetCellPixels * settings_.controls.glyphScale;
  const bool wall = IsMultiDisplay() && windows_.size() > 1;
  const auto dimension = [wall, cellPixels](const double logicalPixels) {
    const double cells = wall ? std::ceil(logicalPixels / cellPixels) : std::round(logicalPixels / cellPixels);
    return static_cast<std::size_t>(std::max(wall ? 1.0 : 8.0, cells));
  };
  const std::size_t nextColumns = dimension(virtualWidth_);
  const std::size_t nextRows = dimension(virtualHeight_);
  if (nextColumns == columns_ && nextRows == rows_) return;
  columns_ = nextColumns;
  rows_ = nextRows;
  if (simulations_.empty()) return;
  for (auto& simulation : simulations_) simulation->Resize(columns_, rows_);
  for (auto& state : renderStates_) state.resize(columns_ * rows_ * 4);
  for (auto& boost : renderBrightnessBoosts_) boost.assign(columns_ * rows_, 0.0f);
  adaptiveResolution_.Reset();
  renderScale_ = 1.0;
  if (reducedMotion_) WarmStaticRain();
}

void MatrixCodeHost::GeometryChanged() {
  RecalculateGeometry();
}

void MatrixCodeHost::RebuildSimulations(const bool preservePresentation) {
  lanes_ = ComputeRainLanes(settings_.controls.density,
    settings_.controls.allowOverlap,
    TierLaneCap(settings_.controls.quality));
  const bool firstBuild = simulations_.empty();
  if (firstBuild) {
    simulations_.reserve(kMaximumRainLanes);
    renderStates_.reserve(kMaximumRainLanes);
    renderBrightnessBoosts_.reserve(kMaximumRainLanes);
    for (std::size_t index = 0; index < kMaximumRainLanes; ++index) {
      simulations_.push_back(std::make_unique<RainSimulation>(columns_, rows_,
        SeedForLane(rainSeed_, index), SimConfig{}, settings_.controls.glyphMode));
      renderStates_.emplace_back(columns_ * rows_ * 4);
      renderBrightnessBoosts_.emplace_back(columns_ * rows_, 0.0f);
    }
  } else {
    for (auto& simulation : simulations_) simulation->SetGlyphMode(settings_.controls.glyphMode);
  }
  std::array<bool, kMaximumRainLanes> active{};
  for (const auto& lane : lanes_) {
    if (lane.index >= simulations_.size()) continue;
    auto& simulation = simulations_[lane.index];
    if (!firstBuild && lane.index != 0 && !laneActive_[lane.index]) simulation->Reset();
    simulation->SetSpawnRateScale(lane.weight);
    Controls controls = settings_.controls;
    controls.density = lane.density;
    if (firstBuild || !preservePresentation) {
      if (windows_.size() > 1) simulation->WarmUpDistributed(controls, 2.5, 1.0 / 60.0);
      else simulation->WarmUp(controls, IsPreview() ? 0.5 : 2.5, 1.0 / 60.0);
    }
    active[lane.index] = true;
  }
  laneActive_ = active;
  if (!imagesConfigured_) {
    imageScheduler_.Configure(settings_.images, rainSeed_, imageEpochSeconds_, UnixSeconds(), windows_.size() > 1);
    imagesConfigured_ = true;
  }
  if (!messagesConfigured_) {
    messageScheduler_.Configure(settings_.messages);
    messagesConfigured_ = true;
  }
  adaptiveResolution_.Reset();
  renderScale_ = 1.0;
}

void MatrixCodeHost::ResetRainToEmpty(const double startSeconds) {
  for (auto& simulation : simulations_) {
    simulation->Reset();
    simulation->SetSpawnRateScale(0.0);
  }
  for (auto& state : renderStates_) std::fill(state.begin(), state.end(), std::uint8_t{0});
  for (auto& boost : renderBrightnessBoosts_) std::fill(boost.begin(), boost.end(), 0.0f);
  laneActive_.fill(false);
  if (!lanes_.empty()) laneActive_[lanes_.front().index] = true;
  rainStartSeconds_ = startSeconds;
  staticFrameRendered_ = false;
}

void MatrixCodeHost::WarmStaticRain() {
  for (const auto& lane : lanes_) {
    Controls controls = settings_.controls;
    controls.density = lane.density;
    auto& simulation = simulations_[lane.index];
    simulation->Reset();
    simulation->SetSpawnRateScale(lane.weight);
    if (windows_.size() > 1) simulation->WarmUpDistributed(controls, 2.5, 1.0 / 60.0);
    else simulation->WarmUp(controls, IsPreview() ? 0.5 : 2.5, 1.0 / 60.0);
    laneActive_[lane.index] = true;
  }
  rainStartSeconds_ = -std::numeric_limits<double>::infinity();
  staticFrameRendered_ = false;
}

void MatrixCodeHost::InitializePresentation() {
  presentationInitialized_ = true;
  introText_.clear();
  introOpacity_ = 0.0f;
  introStartSeconds_ = elapsedSeconds_;
  const bool wall = IsMultiDisplay() && windows_.size() > 1;
  introActive_ = !IsPreview() && options_.mode != platform::LaunchMode::Capture &&
    !wall && !reducedMotion_ &&
    settings_.intro.enabled && !settings_.intro.lines.empty();
  if (wall) rainStartSeconds_ = -std::numeric_limits<double>::infinity();
  else if (introActive_ && !settings_.intro.rainDuringIntro) {
    ResetRainToEmpty(std::numeric_limits<double>::infinity());
  } else {
    rainStartSeconds_ = elapsedSeconds_;
    if (!IsPreview() && !reducedMotion_ && settings_.controls.rampUpMilliseconds > 0.0) {
      ResetRainToEmpty(elapsedSeconds_);
    }
  }
}

double MatrixCodeHost::PresentationTimeSeconds() const {
  return pauseReasons_ != 0 && pauseStartedSeconds_ > 0.0 ? pauseStartedSeconds_ : UnixSeconds();
}

std::string MatrixCodeHost::ResolveText(const std::string_view text) const {
  TokenContext context;
  context.name = settings_.viewerName;
  context.nowMilliseconds = PresentationTimeSeconds() * 1000.0;
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

void MatrixCodeHost::UpdateIntroPresentation() {
  if (!presentationInitialized_) InitializePresentation();
  if (!introActive_) return;
  const double introElapsed = (elapsedSeconds_ - introStartSeconds_) * 1000.0;
  std::vector<IntroLine> resolved = settings_.intro.lines;
  for (auto& line : resolved) line.text = ResolveText(line.text);
  const auto state = ComputeIntroTimeline(resolved, settings_.intro.charMilliseconds,
    settings_.intro.startDelayMilliseconds, settings_.intro.fadeOutMilliseconds, introElapsed);
  if (state.done) {
    introActive_ = false;
    introText_.clear();
    introOpacity_ = 0.0f;
    rainStartSeconds_ = RainStartAfterIntro(rainStartSeconds_, elapsedSeconds_,
      settings_.intro.rainDuringIntro, settings_.intro.postIntroDelayMilliseconds);
    return;
  }
  introText_ = state.visibleText;
  introText_ += IntroCursorVisible(introElapsed) ? "\xE2\x96\x88" : " ";
  introOpacity_ = static_cast<float>(state.opacity);
}

void MatrixCodeHost::UpdateMessages() {
  if (simulations_.empty() || reducedMotion_ || introActive_) return;
  RainSimulationMessageSink sink(*simulations_.front());
  std::vector<MessageRegion> regions;
  if (windows_.size() > 1 && settings_.controls.vignette > 0.0) {
    const double cellPixels = SimConfig{}.targetCellPixels * settings_.controls.glyphScale;
    for (const auto& window : windows_) {
      const QRectF display = window->rain->VirtualGeometry();
      regions.push_back({display.left() / cellPixels, display.top() / cellPixels,
        display.width() / cellPixels, display.height() / cellPixels});
    }
  }
  messageScheduler_.Update(elapsedSeconds_ * 1000.0, sink, regions);
}

void MatrixCodeHost::ApplyImageToBaseLayer(const double nowSeconds) {
  if (simulations_.empty()) return;
  const auto base = simulations_.front()->State();
  renderStates_.front().assign(base.begin(), base.end());
  std::fill(renderBrightnessBoosts_.front().begin(), renderBrightnessBoosts_.front().end(), 0.0f);
  const auto& active = imageScheduler_.Update(nowSeconds);
  const auto* mask = imageScheduler_.ActiveMask();
  if (!active || mask == nullptr) return;
  const auto placement = ComputeImagePlacement(*mask, imageScheduler_.Document(), *active, columns_, rows_);
  if (placement.columns <= 0.0 || placement.rows <= 0.0) return;
  for (std::size_t row = 0; row < rows_; ++row) {
    for (std::size_t column = 0; column < columns_; ++column) {
      const double u = (static_cast<double>(column) + 0.5 - placement.originColumn) / placement.columns;
      const double v = (static_cast<double>(row) + 0.5 - placement.originRow) / placement.rows;
      if (u < 0.0 || u > 1.0 || v < 0.0 || v > 1.0) continue;
      const std::size_t index = row * columns_ + column;
      const std::size_t output = index * 4;
      const std::uint32_t identity = Hash32(rainSeed_ ^
        static_cast<std::uint32_t>(column) * 73856093u ^
        static_cast<std::uint32_t>(row) * 19349663u);
      const auto result = ApplyImageReveal(
        renderStates_.front()[output + 1] / 255.0, renderStates_.front()[output],
        settings_.controls.glyphMode, SampleImageMask(*mask, u, v),
        ImageEdgeFeather(u, v, placement.featherU, placement.featherV),
        ImageFallingGate(static_cast<std::int32_t>(column), static_cast<std::int32_t>(row),
          active->rainElapsedSeconds, rainSeed_), active->intensity, active->scramble,
        identity, active->animationBucket);
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

void MatrixCodeHost::UpdateRenderBuffers() {
  if (reducedMotion_) {
    const auto state = simulations_.front()->State();
    renderStates_.front().assign(state.begin(), state.end());
    std::fill(renderBrightnessBoosts_.front().begin(), renderBrightnessBoosts_.front().end(), 0.0f);
  } else {
    ApplyImageToBaseLayer(PresentationTimeSeconds());
  }
  for (const auto& lane : lanes_) {
    if (lane.index == 0 || lane.index >= simulations_.size()) continue;
    const auto state = simulations_[lane.index]->State();
    renderStates_[lane.index].assign(state.begin(), state.end());
    std::fill(renderBrightnessBoosts_[lane.index].begin(), renderBrightnessBoosts_[lane.index].end(), 0.0f);
  }
  renderViews_.clear();
  for (const auto& lane : lanes_) {
    renderViews_.push_back({renderStates_[lane.index], renderBrightnessBoosts_[lane.index],
      static_cast<std::uint32_t>(columns_), static_cast<std::uint32_t>(rows_),
      static_cast<float>(lane.offsetCells), 1.0f});
  }
}

Controls MatrixCodeHost::EffectiveControls() const {
  if (IsCapture()) return settings_.controls;
  const QDate date = QDate::currentDate();
  const QDateTime start(date.startOfDay());
  const QDateTime end(date.addDays(1).startOfDay());
  const bool fullMoon = const_cast<FullMoonDayCache&>(fullMoonCache_).ContainsFullMoon(
    static_cast<double>(start.toMSecsSinceEpoch()), static_cast<double>(end.toMSecsSinceEpoch()));
  return EffectiveControlsForLocalDate(settings_.controls, date.month(), date.day(), fullMoon);
}

void MatrixCodeHost::Render(RainWidget& widget, render::OpenGLRenderer& renderer) {
  if (!renderer.IsInitialized() || renderViews_.empty()) return;
  render::FrameParameters parameters;
  parameters.controls = EffectiveControls();
  parameters.palette = PaletteForControls(parameters.controls);
  renderedPreset_ = parameters.controls.preset;
  parameters.overlayText = introText_;
  parameters.overlayOpacity = introOpacity_;
  parameters.toastText = toastText_;
  const double toastAge = std::max(0.0, UnixSeconds() - toastStartSeconds_);
  if (!toastText_.empty() && toastAge < (reducedMotion_ ? 1.7 : 1.88)) {
    const double linear = reducedMotion_ ? 1.0 : toastAge < 0.18
      ? toastAge / 0.18 : toastAge <= 1.7 ? 1.0 : 1.0 - (toastAge - 1.7) / 0.18;
    const double eased = std::clamp(linear, 0.0, 1.0);
    parameters.toastOpacity = static_cast<float>(eased * eased * (3.0 - 2.0 * eased));
    parameters.toastOffsetDips = -8.0f * (1.0f - parameters.toastOpacity);
  }
  RainWindow* window = WindowFor(widget);
  if (window != nullptr && window->hudVisible && !IsSaver() && !IsPreview()) {
    const double now = UnixSeconds();
    if (window->hudText.isEmpty() || now >= window->nextHudUpdateSeconds) {
      const double smoothed = adaptiveResolution_.SmoothedMilliseconds();
      const int fps = smoothed > 0.0 ? qRound(1000.0 / smoothed) : 0;
      const QSize backing = widget.size() * widget.devicePixelRatioF() * renderScale_;
      window->hudText = QString("%1 fps · %2% res · %3×%4")
        .arg(fps).arg(qRound(renderScale_ * 100.0)).arg(backing.width()).arg(backing.height());
      window->nextHudUpdateSeconds = now + 0.25;
    }
    parameters.hudText = window->hudText.toUtf8().toStdString();
  }
  const QRectF display = widget.VirtualGeometry();
  parameters.cellPixels = static_cast<float>(SimConfig{}.targetCellPixels * settings_.controls.glyphScale);
  parameters.virtualOriginX = static_cast<float>(display.left());
  parameters.virtualOriginY = static_cast<float>(display.top());
  const float logicalPerPixel = IsCapture()
    ? 1.0f
    : static_cast<float>(1.0 / widget.devicePixelRatioF());
  parameters.logicalPerPixelX = logicalPerPixel;
  parameters.logicalPerPixelY = logicalPerPixel;
  parameters.adaptiveScale = static_cast<float>(renderScale_);
  parameters.elapsedSeconds = static_cast<float>(elapsedSeconds_);
  parameters.presentationMode = PresentationModeForWindowCount(windows_.size());
  if (!renderer.Render(renderViews_, parameters, widget.defaultFramebufferObject())) {
    const QString diagnostic = FromUtf8(renderer.Diagnostics().lastError);
    if (!widget.BeginRendererRecovery()) {
      QTimer::singleShot(0, &widget, [this, &widget, diagnostic] {
        HandleRendererFailure(widget, diagnostic);
      });
      return;
    }
    renderer.Cleanup();
    const bool restored = renderer.Initialize(widget.context());
    const qreal ratio = widget.devicePixelRatioF();
    const bool resized = restored && renderer.Resize(
      IsCapture() ? kCaptureWidth
                  : static_cast<std::uint32_t>(std::max(1, qRound(widget.width() * ratio))),
      IsCapture() ? kCaptureHeight
                  : static_cast<std::uint32_t>(std::max(1, qRound(widget.height() * ratio))));
    if (!IsCapture()) ShowToast("GPU CONTEXT RECOVERING");
    if (resized) widget.update();
    else {
      const QString recoveryDiagnostic = FromUtf8(renderer.Diagnostics().lastError);
      QTimer::singleShot(0, &widget, [this, &widget, recoveryDiagnostic] {
        HandleRendererFailure(widget, recoveryDiagnostic);
      });
    }
    return;
  }
  widget.ResetRendererRecovery();
  if (options_.mode == platform::LaunchMode::Capture && !captureSaved_) {
    captureSaved_ = true;
    const QImage capture = renderer.CaptureFrame();
    if (!capture.save(options_.capturePath)) {
      qCritical().noquote() << "Matrix Code could not save capture to" << options_.capturePath;
      QTimer::singleShot(0, &application_, [] { QCoreApplication::exit(3); });
    } else {
      QTimer::singleShot(0, &application_, [] { QCoreApplication::quit(); });
    }
  }
}

void MatrixCodeHost::Tick() {
  const qint64 nowNanoseconds = frameClock_.nsecsElapsed();
  const double rawFrameElapsed = std::max(
    0.0, static_cast<double>(nowNanoseconds - previousNanoseconds_) / 1.0e9);
  previousNanoseconds_ = nowNanoseconds;
  const bool wasHidden = (pauseReasons_ & kPauseHidden) != 0;
  const bool anyWindowVisible = std::any_of(windows_.begin(), windows_.end(), [](const auto& window) {
    return window->container->isVisible() && !window->container->isMinimized();
  });
  SetPauseReason(kPauseHidden, !anyWindowVisible);
  if (rawFrameElapsed > 1.0 && !wasHidden && pauseReasons_ == 0) {
    ShiftPresentationTimelines(rawFrameElapsed);
    adaptiveResolution_.Reset();
    renderScale_ = 1.0;
  }
  const double frameElapsed = rawFrameElapsed > 1.0
    ? 0.0 : std::clamp(rawFrameElapsed, 0.0, 0.25);
  PollSettings();
  const bool frozen = Frozen();
  if (!frozen) elapsedSeconds_ += frameElapsed;
  const Controls effectiveControls = EffectiveControls();
  if (effectiveControls.preset != renderedPreset_) staticFrameRendered_ = false;
  if (frozen && staticFrameRendered_ && toastText_.empty()) {
    RefreshTimerCadence();
    return;
  }
  if (simulations_.empty()) return;
  UpdateIntroPresentation();
  const bool rainStarted = elapsedSeconds_ >= rainStartSeconds_;
  if (rainStarted) UpdateMessages();
  const double rampDuration = IsPreview() || (IsMultiDisplay() && windows_.size() > 1)
    ? 0.0 : settings_.controls.rampUpMilliseconds / 1000.0;
  const double progress = rampDuration <= 0.0
    ? (rainStarted ? 1.0 : 0.0)
    : std::clamp((elapsedSeconds_ - rainStartSeconds_) / rampDuration, 0.0, 1.0);
  const double easedRamp = RainRampEase(progress);
  const auto plan = frozen || options_.mode == platform::LaunchMode::Capture
    ? SimulationStepPlan{} : PlanSimulationSteps(frameElapsed);
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
  else if (!userPaused_ && options_.mode != platform::LaunchMode::Capture) {
    renderScale_ = adaptiveResolution_.Update(std::max(1.0, frameElapsed * 1000.0));
  }
  UpdateRenderBuffers();
  for (const auto& window : windows_) {
    if (window->container->isVisible() && !window->container->isMinimized()) window->rain->update();
  }
  if (!toastText_.empty() && UnixSeconds() - toastStartSeconds_ >= (reducedMotion_ ? 1.7 : 1.88)) {
    toastText_.clear();
  }
  if (frozen) staticFrameRendered_ = true;
  RefreshTimerCadence();
}

void MatrixCodeHost::PollSettings() {
  const double clock = UnixSeconds();
  if (clock < nextSettingsPollSeconds_) return;
  nextSettingsPollSeconds_ = clock + 1.0;
  const bool reducedMotion = reducedMotionMonitor_.Requested();
  if (reducedMotion != reducedMotion_) {
    reducedMotion_ = reducedMotion;
    SetPauseReason(kPauseReducedMotion, reducedMotion_);
    if (reducedMotion_) {
      presentationInitialized_ = true;
      introActive_ = false;
      introText_.clear();
      introOpacity_ = 0.0f;
      rainStartSeconds_ = -std::numeric_limits<double>::infinity();
      WarmStaticRain();
    }
    staticFrameRendered_ = false;
  }
  if (options_.mode == platform::LaunchMode::Capture) return;
  if (settingsOpen_) return;
  settingsFile_.refresh();
  if (!settingsFile_.exists()) {
    if (settingsFileKnown_) {
      settingsFileKnown_ = false;
      settingsModified_ = {};
      ApplySettings(store_.Load());
    }
    return;
  }
  const QDateTime modified = settingsFile_.lastModified();
  if (!settingsFileKnown_) {
    settingsFileKnown_ = true;
    settingsModified_ = modified;
    ApplySettings(store_.Load());
    return;
  }
  if (modified == settingsModified_) return;
  settingsModified_ = modified;
  ApplySettings(store_.Load());
}

void MatrixCodeHost::RefreshSettingsStamp() {
  settingsFile_.refresh();
  settingsFileKnown_ = settingsFile_.exists();
  settingsModified_ = settingsFileKnown_ ? settingsFile_.lastModified() : QDateTime{};
}

void MatrixCodeHost::ApplySettings(SettingsSnapshot settings, const bool preview) {
  const bool structureChanged = settings.controls.density != settings_.controls.density ||
    settings.controls.glyphMode != settings_.controls.glyphMode ||
    settings.controls.allowOverlap != settings_.controls.allowOverlap ||
    settings.controls.quality != settings_.controls.quality;
  const bool geometryChanged = settings.controls.glyphScale != settings_.controls.glyphScale;
  const bool messagesChanged = !SameMessages(settings.messages, settings_.messages);
  const bool imagesChanged = !SameImages(settings.images, settings_.images);
  const bool rampChanged = settings.controls.rampUpMilliseconds != settings_.controls.rampUpMilliseconds;
  settings_ = std::move(settings);
  staticFrameRendered_ = false;
  if (imagesChanged || !imagesConfigured_) {
    imageScheduler_.Configure(settings_.images, rainSeed_, imageEpochSeconds_, UnixSeconds(), windows_.size() > 1);
    imagesConfigured_ = true;
  }
  if (messagesChanged || !messagesConfigured_) {
    messageScheduler_.Configure(settings_.messages);
    messagesConfigured_ = true;
  }
  if (geometryChanged) RecalculateGeometry();
  if (structureChanged) RebuildSimulations();
  if (reducedMotion_ && (structureChanged || geometryChanged)) WarmStaticRain();
  else if (rampChanged && !preview && !IsMultiDisplay() && settings_.controls.rampUpMilliseconds > 0.0) {
    ResetRainToEmpty(elapsedSeconds_);
  }
  UpdateRenderBuffers();
  for (const auto& window : windows_) window->rain->update();
}

void MatrixCodeHost::OpenSettings(const ui::SettingsPage page, QWidget* owner) {
  if (settingsOpen_ || IsSaver() || IsPreview()) return;
  settingsOpen_ = true;
  const SettingsSnapshot before = settings_;
  SetPauseReason(kPauseModal, true);
  ui::SettingsDialog dialog(settings_, page, owner);
  dialog.SetPreviewCallback([this, &dialog, &before](
      const SettingsSnapshot& preview, const ui::SettingsPage previewPage) {
    const std::uint64_t generation = ++settingsPreviewGeneration_;
    dialog.hide();
    SetPauseReason(kPauseModal, false);
    SettingsSnapshot livePreview = preview;
    if (previewPage == ui::SettingsPage::Intro) livePreview.intro.enabled = true;
    if (previewPage == ui::SettingsPage::Images && !livePreview.images.images.empty()) {
      livePreview.images.enabled = true;
      livePreview.images.frequencyMilliseconds = 500.0;
    }
    ApplySettings(std::move(livePreview), true);
    double previewMilliseconds = 3000.0;
    if (previewPage == ui::SettingsPage::Intro) {
      presentationInitialized_ = false;
      InitializePresentation();
      previewMilliseconds = IntroTotalDurationMilliseconds(preview.intro);
    } else if (previewPage == ui::SettingsPage::Messages && !simulations_.empty()) {
      RainSimulationMessageSink sink(*simulations_.front());
      messageScheduler_.PreviewOne(elapsedSeconds_ * 1000.0, sink, preview.messages);
      previewMilliseconds = preview.messages.appearMilliseconds +
        preview.messages.persistenceMilliseconds + preview.messages.disappearMilliseconds;
    } else if (previewPage == ui::SettingsPage::Images) {
      previewMilliseconds = 625.0 +
        preview.images.appearMilliseconds + preview.images.persistenceMilliseconds +
        preview.images.disappearMilliseconds;
    }
    const int duration = static_cast<int>(std::clamp(previewMilliseconds, 500.0, 30000.0));
    QTimer::singleShot(duration, &dialog, [this, &dialog, &before, generation] {
      if (settingsOpen_ && generation == settingsPreviewGeneration_) {
        ApplySettings(before, true);
        messageScheduler_.Configure(settings_.messages);
        imageScheduler_.Configure(
          settings_.images, rainSeed_, imageEpochSeconds_, UnixSeconds(), windows_.size() > 1);
        messagesConfigured_ = true;
        imagesConfigured_ = true;
        presentationInitialized_ = true;
        introActive_ = false;
        introText_.clear();
        introOpacity_ = 0.0f;
        WarmStaticRain();
        UpdateRenderBuffers();
        SetPauseReason(kPauseModal, true);
        dialog.show();
        dialog.raise();
        dialog.activateWindow();
      }
    });
  });
  const int result = dialog.exec();
  ++settingsPreviewGeneration_;
  if (result == QDialog::Accepted) {
    QString diagnostic;
    if (store_.Save(dialog.Result(), &diagnostic)) {
      ApplySettings(dialog.Result());
      RefreshSettingsStamp();
    } else {
      QMessageBox::critical(owner, QObject::tr("Could not save settings"), diagnostic);
      ApplySettings(before);
    }
  } else {
    ApplySettings(before);
  }
  SetPauseReason(kPauseModal, false);
  settingsOpen_ = false;
}

void MatrixCodeHost::ToggleDocument(const bool images) {
  SettingsSnapshot next = settings_;
  bool enabled = false;
  if (images) { next.images.enabled = !next.images.enabled; enabled = next.images.enabled; }
  else { next.messages.enabled = !next.messages.enabled; enabled = next.messages.enabled; }
  QString diagnostic;
  if (!store_.Save(next, &diagnostic)) {
    QMessageBox::critical(nullptr, QObject::tr("Could not save settings"), diagnostic);
    return;
  }
  ApplySettings(std::move(next));
  RefreshSettingsStamp();
  ShowToast(std::string(images ? "IMAGES " : "MESSAGES ") + (enabled ? "ENABLED" : "DISABLED"));
}

void MatrixCodeHost::NudgeDensity(const double factor) {
  SettingsSnapshot next = settings_;
  next.controls.density = std::clamp(next.controls.density * factor, 0.1, 100.0);
  if (store_.Save(next)) {
    ApplySettings(std::move(next));
    RefreshSettingsStamp();
  }
}

bool MatrixCodeHost::SkipIntro() {
  if (!introActive_) return false;
  introActive_ = false;
  introText_.clear();
  introOpacity_ = 0.0f;
  rainStartSeconds_ = RainStartAfterIntro(rainStartSeconds_, elapsedSeconds_,
    settings_.intro.rainDuringIntro, settings_.intro.postIntroDelayMilliseconds);
  staticFrameRendered_ = false;
  return true;
}

void MatrixCodeHost::ShowToast(std::string text) {
  toastText_ = std::move(text);
  toastStartSeconds_ = UnixSeconds();
  staticFrameRendered_ = false;
  RefreshTimerCadence();
}

void MatrixCodeHost::RefreshTimerCadence() {
  const int interval = Frozen() && toastText_.empty()
    ? kIdlePollMilliseconds : kFrameMilliseconds;
  if (timer_.interval() != interval) timer_.setInterval(interval);
}

RainWindow* MatrixCodeHost::WindowFor(RainWidget& widget) {
  const auto found = std::find_if(windows_.begin(), windows_.end(), [&widget](const auto& candidate) {
    return candidate->rain == &widget;
  });
  return found != windows_.end() ? found->get() : nullptr;
}

RainWindow* MatrixCodeHost::ControlsWindow() {
  if (windows_.empty()) return nullptr;
  const QPointF centre(virtualWidth_ * 0.5, virtualHeight_ * 0.5);
  auto found = std::min_element(windows_.begin(), windows_.end(), [centre](const auto& left, const auto& right) {
    const QPointF leftCentre = left->rain->VirtualGeometry().center();
    const QPointF rightCentre = right->rain->VirtualGeometry().center();
    const double leftDistance = std::pow(leftCentre.x() - centre.x(), 2.0) +
      std::pow(leftCentre.y() - centre.y(), 2.0);
    const double rightDistance = std::pow(rightCentre.x() - centre.x(), 2.0) +
      std::pow(rightCentre.y() - centre.y(), 2.0);
    return leftDistance < rightDistance;
  });
  return found != windows_.end() ? found->get() : nullptr;
}

void MatrixCodeHost::HandleKey(RainWidget& widget, QKeyEvent& event) {
  event.ignore();
  if (IsSaver()) {
    if (IsStandaloneSaver()) ExitAll();
    event.accept();
    return;
  }
  const bool shift = event.modifiers().testFlag(Qt::ShiftModifier);
  const bool alt = event.modifiers().testFlag(Qt::AltModifier);
  const bool control = event.modifiers().testFlag(Qt::ControlModifier) ||
    event.modifiers().testFlag(Qt::MetaModifier);
  if (event.key() == Qt::Key_Escape) {
    if (SkipIntro()) { event.accept(); return; }
    if (IsMultiDisplay()) { ExitAll(); event.accept(); return; }
    if (RainWindow* window = WindowFor(widget); window != nullptr && window->fullscreen) {
      ToggleFullscreen(widget); event.accept(); return;
    }
  }
  if (event.isAutoRepeat()) return;
  if (IsMultiDisplay() && WindowFor(widget) != ControlsWindow()) {
    event.accept();
    return;
  }
  if (alt && !control && event.key() == Qt::Key_F) {
    if (RainWindow* window = WindowFor(widget); window != nullptr) {
      const bool visible = !window->hudVisible;
      for (const auto& candidate : windows_) {
        candidate->hudVisible = visible;
        candidate->hudText.clear();
      }
      SaveHudVisible(visible);
      ShowToast(visible ? "PERFORMANCE HUD ENABLED" : "PERFORMANCE HUD DISABLED");
    }
    event.accept(); return;
  }
  if (control || alt) return;
  if (IsMultiDisplay()) {
    RainWindow* controls = ControlsWindow();
    if (event.key() == Qt::Key_H && controls != nullptr) {
      OpenSettings(ui::SettingsPage::Rain, controls->rain);
      event.accept();
    } else if (event.key() == Qt::Key_Minus) {
      NudgeDensity(1.0 / 1.2);
      event.accept();
    } else if (event.key() == Qt::Key_Equal || event.key() == Qt::Key_Plus) {
      NudgeDensity(1.2);
      event.accept();
    }
    return;
  }
  if (event.key() == Qt::Key_H) { OpenSettings(ui::SettingsPage::Rain, &widget); event.accept(); }
  else if (event.key() == Qt::Key_I) { OpenSettings(ui::SettingsPage::Intro, &widget); event.accept(); }
  else if (event.key() == Qt::Key_C) { OpenSettings(ui::SettingsPage::Countdown, &widget); event.accept(); }
  else if (event.key() == Qt::Key_M && shift) { ToggleDocument(false); event.accept(); }
  else if (event.key() == Qt::Key_M) { OpenSettings(ui::SettingsPage::Messages, &widget); event.accept(); }
  else if (event.key() == Qt::Key_X && shift) { ToggleDocument(true); event.accept(); }
  else if (event.key() == Qt::Key_X) { OpenSettings(ui::SettingsPage::Images, &widget); event.accept(); }
  else if (event.key() == Qt::Key_N) { ToggleDocument(false); event.accept(); }
  else if (event.key() == Qt::Key_P) {
    if (reducedMotion_) { event.accept(); return; }
    userPaused_ = !userPaused_;
    SetPauseReason(kPauseUser, userPaused_);
    ShowToast(userPaused_ ? "ANIMATION PAUSED" : "ANIMATION RESUMED");
    event.accept();
  } else if (event.key() == Qt::Key_Minus) { NudgeDensity(1.0 / 1.2); event.accept(); }
  else if (event.key() == Qt::Key_Equal || event.key() == Qt::Key_Plus) { NudgeDensity(1.2); event.accept(); }
  else if (event.key() == Qt::Key_F || event.key() == Qt::Key_F11) { ToggleFullscreen(widget); event.accept(); }
}

void MatrixCodeHost::HandleMousePress(RainWidget&, QMouseEvent& event) {
  event.ignore();
  if (IsSaver()) {
    if (IsStandaloneSaver()) ExitAll();
    event.accept();
    return;
  }
  if (SkipIntro()) { event.accept(); return; }
  if (event.button() != Qt::LeftButton || IsMultiDisplay() || IsPreview()) return;
  const qint64 now = frameClock_.elapsed();
  clickCount_ = now - lastClickMilliseconds_ <= kMultiClickMilliseconds ? clickCount_ + 1 : 1;
  lastClickMilliseconds_ = now;
  if (clickCount_ >= 3) {
    clickCount_ = 0;
    StartMultiMonitor();
    event.accept();
  }
}

void MatrixCodeHost::HandleDoubleClick(RainWidget& widget, QMouseEvent& event) {
  event.ignore();
  if (IsSaver()) {
    if (IsStandaloneSaver()) ExitAll();
    event.accept();
    return;
  }
  if (SkipIntro()) { event.accept(); return; }
  if (event.button() != Qt::LeftButton || IsMultiDisplay() || IsPreview()) return;
  clickCount_ = std::max(clickCount_, 2);
  const qint64 expectedClick = lastClickMilliseconds_;
  QTimer::singleShot(kMultiClickMilliseconds, &widget, [this, &widget, expectedClick] {
    if (clickCount_ == 2 && lastClickMilliseconds_ == expectedClick) {
      clickCount_ = 0;
      ToggleFullscreen(widget);
    }
  });
  event.accept();
}

void MatrixCodeHost::HandleMouseMove(RainWidget&, QMouseEvent& event) {
  event.ignore();
  if (IsStandaloneSaver() && saverGrace_.elapsed() > 300 &&
      (std::abs(QCursor::pos().x() - saverInitialCursor_.x()) >= 4 ||
       std::abs(QCursor::pos().y() - saverInitialCursor_.y()) >= 4)) {
    ExitAll();
    event.accept();
  }
}

void MatrixCodeHost::HandleWheel(QWheelEvent& event) {
  event.ignore();
  if (IsSaver()) {
    if (IsStandaloneSaver()) ExitAll();
    event.accept();
  }
}

void MatrixCodeHost::HandlePointerActivity(QEvent& event) {
  event.ignore();
  if (IsSaver()) {
    if (IsStandaloneSaver()) ExitAll();
    event.accept();
  }
}

void MatrixCodeHost::HandleRendererFailure(
    RainWidget& widget, const QString& diagnostic) {
  if (exiting_) return;
  if (!options_.forceSoftware) {
    if (options_.xscreensaverHosted) {
      QCoreApplication::exit(kSoftwareFallbackExitCode);
      return;
    }
    if (StartSoftwareFallback()) {
      ExitAll();
      return;
    }
  }
  if (options_.mode == platform::LaunchMode::Capture) {
    QCoreApplication::exit(3);
    return;
  }
  if (IsSaver() || IsPreview()) {
    ExitAll();
    return;
  }
  QMessageBox::critical(&widget, QObject::tr("Matrix Code renderer"),
    QObject::tr("OpenGL initialization failed.\n\n%1").arg(diagnostic));
  ExitAll();
}

void MatrixCodeHost::ToggleFullscreen(RainWidget& widget) {
  if (IsMultiDisplay() || IsPreview()) return;
  RainWindow* window = WindowFor(widget);
  if (window == nullptr) return;
  if (window->fullscreen) window->container->showNormal();
  else window->container->showFullScreen();
  window->fullscreen = !window->fullscreen;
  QTimer::singleShot(0, window->rain, [this] { RecalculateGeometry(); });
}

void MatrixCodeHost::StartMultiMonitor() {
  if (IsMultiDisplay() || IsPreview()) return;
  if (!QProcess::startDetached(QCoreApplication::applicationFilePath(), {"--multi-monitor"})) {
    ShowToast("COULD NOT START MULTI-MONITOR MODE");
    return;
  }
  ExitAll();
}

void MatrixCodeHost::SetPauseReason(const PauseReason reason, const bool paused) {
  const bool wasPaused = pauseReasons_ != 0;
  if (paused) pauseReasons_ |= reason;
  else pauseReasons_ &= ~reason;
  const bool isPaused = pauseReasons_ != 0;
  if (!wasPaused && isPaused) {
    pauseStartedSeconds_ = UnixSeconds();
  } else if (wasPaused && !isPaused) {
    const double duration = pauseStartedSeconds_ > 0.0
      ? std::max(0.0, UnixSeconds() - pauseStartedSeconds_) : 0.0;
    pauseStartedSeconds_ = 0.0;
    ShiftPresentationTimelines(duration);
    previousNanoseconds_ = frameClock_.nsecsElapsed();
    adaptiveResolution_.Reset();
    renderScale_ = 1.0;
    staticFrameRendered_ = false;
  }
  RefreshTimerCadence();
}

void MatrixCodeHost::ShiftPresentationTimelines(const double durationSeconds) {
  if (!std::isfinite(durationSeconds) || durationSeconds <= 0.0) return;
  epochSeconds_ += durationSeconds;
  if (windows_.size() <= 1) {
    imageEpochSeconds_ += durationSeconds;
    imageScheduler_.ShiftTimelineBy(durationSeconds);
  }
}

void MatrixCodeHost::HandleClose(QCloseEvent& event) {
  if (IsMultiDisplay() && !exiting_) {
    event.ignore();
    ExitAll();
  } else {
    event.accept();
  }
}

void MatrixCodeHost::HandleFocusOut() {
  if (IsStandaloneSaver() && saverGrace_.elapsed() > 300) ExitAll();
}

void MatrixCodeHost::ScreensChanged() {
  if (IsMultiDisplay()) {
    ExitAll();
  } else {
    QTimer::singleShot(0, &application_, [this] { RecalculateGeometry(); });
  }
}

void MatrixCodeHost::HandleEmbeddedWindowDestroyed() {
  if (!IsEmbedded() || exiting_) return;
  exiting_ = true;
  timer_.stop();
  for (const auto& window : windows_) {
    if (window->rain != nullptr) window->rain->setUpdatesEnabled(false);
  }
  application_.exit(0);
}

void MatrixCodeHost::ExitAll() {
  if (exiting_) return;
  exiting_ = true;
  timer_.stop();
  if (saverCursorHidden_) {
    application_.restoreOverrideCursor();
    saverCursorHidden_ = false;
  }
  for (const auto& window : windows_) {
    if (window->container != nullptr) window->container->close();
  }
  QCoreApplication::quit();
}

}  // namespace

int RunMatrixCodeHost(
    QApplication& application, const platform::CommandLineOptions& options) {
  MatrixCodeHost host(application, options);
  return host.Run();
}

}  // namespace matrixcode::app
