#include "TestHarness.h"

#include <xcb/xcb.h>

#include <QByteArray>

#include "matrixcode/platform/X11Window.h"

void RunX11WindowTests() {
  using matrixcode::platform::X11WindowLifecycleMonitor;

  int destructionCount = 0;
  X11WindowLifecycleMonitor monitor([&destructionCount] { ++destructionCount; });

  xcb_destroy_notify_event_t destroyed{};
  destroyed.response_type = XCB_DESTROY_NOTIFY;
  destroyed.window = 0x200u;

  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("windows_generic_MSG"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 0);

  monitor.Watch(0x100u, 0x200u);
  xcb_generic_event_t exposed{};
  exposed.response_type = XCB_EXPOSE;
  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &exposed, nullptr));
  MX_EXPECT_EQ(destructionCount, 0);

  destroyed.window = 0x300u;
  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 0);

  destroyed.response_type = XCB_DESTROY_NOTIFY | 0x80u;
  destroyed.window = 0x200u;
  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 1);

  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 1);

  monitor.Watch(0x100u, 0x200u);
  destroyed.response_type = XCB_DESTROY_NOTIFY;
  destroyed.window = 0x100u;
  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 2);

  monitor.Watch(0x100u, 0x200u);
  monitor.Stop();
  MX_EXPECT(!monitor.nativeEventFilter(
    QByteArrayLiteral("xcb_generic_event_t"), &destroyed, nullptr));
  MX_EXPECT_EQ(destructionCount, 2);
}
