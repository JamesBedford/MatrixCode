#include "matrixcode/platform/X11Window.h"

#include <X11/Xlib.h>

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

}  // namespace matrixcode::platform
