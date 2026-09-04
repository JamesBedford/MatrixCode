#pragma once

#include <functional>
#include <optional>

#include <QAbstractNativeEventFilter>
#include <QSize>
#include <QtGlobal>

namespace matrixcode::platform {

[[nodiscard]] std::optional<QSize> QueryX11WindowSize(quint64 windowId);

class X11WindowLifecycleMonitor final : public QAbstractNativeEventFilter {
 public:
  using DestroyedCallback = std::function<void()>;

  explicit X11WindowLifecycleMonitor(DestroyedCallback destroyedCallback);

  void Watch(quint64 hostWindowId, quint64 embeddedWindowId) noexcept;
  void Stop() noexcept;

  bool nativeEventFilter(
    const QByteArray& eventType, void* message, qintptr* result) override;

 private:
  DestroyedCallback destroyedCallback_;
  quint64 hostWindowId_ = 0;
  quint64 embeddedWindowId_ = 0;
};

}  // namespace matrixcode::platform
