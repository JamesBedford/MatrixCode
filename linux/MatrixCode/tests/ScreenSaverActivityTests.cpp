#include "TestHarness.h"

#include <limits>

#include "matrixcode/platform/ScreenSaverActivity.h"

void RunScreenSaverActivityTests() {
  using matrixcode::platform::ScreenSaverActivity;
  const int firstDisplay = 1;
  const int secondDisplay = 2;

  ScreenSaverActivity startup;
  MX_EXPECT(!startup.ObservePointer(&firstDisplay, 100.0, 200.0, 0));
  MX_EXPECT(!startup.ObservePointer(&secondDisplay, 1.0, 2.0, 299));
  MX_EXPECT(!startup.ObservePointer(&firstDisplay, 300.0, 400.0, 300));
  MX_EXPECT(!startup.ObservePointer(&firstDisplay, 300.0, 400.0, 301));
  MX_EXPECT(!startup.ObservePointer(&firstDisplay, 303.999, 400.0, 302));
  MX_EXPECT(startup.ObservePointer(&firstDisplay, 304.0, 400.0, 303));

  ScreenSaverActivity vertical;
  MX_EXPECT(!vertical.ObservePointer(&firstDisplay, 0.0, 0.0, 300));
  MX_EXPECT(vertical.ObservePointer(&firstDisplay, 0.0, -4.0, 301));

  ScreenSaverActivity fractional;
  MX_EXPECT(!fractional.ObservePointer(&firstDisplay, 100.5, 200.25, 100));
  MX_EXPECT(!fractional.ObservePointer(&firstDisplay, 103.5, 203.25, 400));
  MX_EXPECT(fractional.ObservePointer(&firstDisplay, 104.5, 200.25, 500));

  ScreenSaverActivity crossing;
  MX_EXPECT(!crossing.ObservePointer(&firstDisplay, 100.0, 200.0, 10));
  MX_EXPECT(crossing.ObservePointer(&secondDisplay, 100.0, 200.0, 301));

  ScreenSaverActivity firstLateEvent;
  MX_EXPECT(!firstLateEvent.ObservePointer(&firstDisplay, 900.0, 600.0, 1000));
  MX_EXPECT(!firstLateEvent.ObservePointer(&firstDisplay, 900.0, 600.0, 1001));
  MX_EXPECT(firstLateEvent.ObservePointer(&firstDisplay, 896.0, 600.0, 1002));

  ScreenSaverActivity invalidCoordinates;
  MX_EXPECT(!invalidCoordinates.ObservePointer(
    &firstDisplay, std::numeric_limits<double>::quiet_NaN(), 0.0, 0));
  MX_EXPECT(!invalidCoordinates.ObservePointer(
    &firstDisplay, 0.0, std::numeric_limits<double>::infinity(), 0));
  MX_EXPECT(!invalidCoordinates.ObservePointer(&firstDisplay, 10.0, 20.0, 301));
  MX_EXPECT(invalidCoordinates.ObservePointer(&firstDisplay, 14.0, 20.0, 302));

  ScreenSaverActivity focus;
  focus.ObserveApplicationFocus(false);
  MX_EXPECT(!focus.ShouldDismissForInactivity(false, 1000));
  focus.ObserveApplicationFocus(true);
  MX_EXPECT(!focus.ShouldDismissForInactivity(true, 1000));
  focus.ObserveApplicationFocus(false);
  MX_EXPECT(!focus.ShouldDismissForInactivity(false, 300));
  MX_EXPECT(focus.ShouldDismissForInactivity(false, 301));
  // A deferred check sees restored application focus during a monitor transition.
  focus.ObserveApplicationFocus(true);
  MX_EXPECT(!focus.ShouldDismissForInactivity(true, 301));
  MX_EXPECT(focus.ShouldDismissForInactivity(false, 302));
}
