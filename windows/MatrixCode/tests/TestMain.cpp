#include <exception>
#include <iostream>

#include "TestHarness.h"

void RunControllersTests();
void RunDisplayTopologyTests();
void RunIntroTimelineTests();
void RunImageRevealTests();
void RunImageImportTests();
void RunMessageSchedulerTests();
void RunRainSimulationTests();
void RunScreenSaverArgsTests();
void RunSettingsTests();
void RunTokenResolverTests();
void RunUtf8Tests();

int main() {
  try {
    RunControllersTests();
    RunDisplayTopologyTests();
    RunIntroTimelineTests();
    RunImageRevealTests();
    RunImageImportTests();
    RunMessageSchedulerTests();
    RunRainSimulationTests();
    RunScreenSaverArgsTests();
    RunSettingsTests();
    RunTokenResolverTests();
    RunUtf8Tests();
    std::cout << "MatrixCodeNativeTests: " << matrixcode::test::assertions << " assertions passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "MatrixCodeNativeTests failed: " << error.what() << '\n';
    return 1;
  }
}
