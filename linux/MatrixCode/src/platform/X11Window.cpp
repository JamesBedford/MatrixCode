#include "matrixcode/platform/X11Window.h"

#include <utility>

#include <X11/Xlib.h>
#include <xcb/xcb.h>

namespace matrixcode::platform {

std::optional<QSize> QueryX11WindowSize(const quint64 windowId) {
  if (windowId == 0) return std::nullopt;
  Display* display = XOpenDisplay(nullptr);
  if (display == nullptr) return std::nullopt;
  XWindowAttributes attributes{};
  const int result = XGetWindowAttributes(
    display, static_cast<Window>(windowId), &attributes);
  XCloseDisplay(display);
  if (result == 0 || attributes.width <= 0 || attributes.height <= 0) {
    return std::nullopt;
  }
  return QSize(attributes.width, attributes.height);
}

X11WindowLifecycleMonitor::X11WindowLifecycleMonitor(
    DestroyedCallback destroyedCallback)
    : destroyedCallback_(std::move(destroyedCallback)) {}

void X11WindowLifecycleMonitor::Watch(
    const quint64 hostWindowId, const quint64 embeddedWindowId) noexcept {
  hostWindowId_ = hostWindowId;
  embeddedWindowId_ = embeddedWindowId;
}

void X11WindowLifecycleMonitor::Stop() noexcept {
  hostWindowId_ = 0;
  embeddedWindowId_ = 0;
}

bool X11WindowLifecycleMonitor::nativeEventFilter(
    const QByteArray& eventType, void* message, qintptr*) {
  if (hostWindowId_ == 0 || embeddedWindowId_ == 0 || message == nullptr ||
      eventType != QByteArrayLiteral("xcb_generic_event_t")) return false;
  const auto* event = static_cast<const xcb_generic_event_t*>(message);
  if ((event->response_type & 0x7fu) != XCB_DESTROY_NOTIFY) return false;
  const auto* destroyed = reinterpret_cast<const xcb_destroy_notify_event_t*>(event);
  if (destroyed->window != hostWindowId_ && destroyed->window != embeddedWindowId_) {
    return false;
  }
  Stop();
  if (destroyedCallback_) destroyedCallback_();
  return false;
}

}  // namespace matrixcode::platform
