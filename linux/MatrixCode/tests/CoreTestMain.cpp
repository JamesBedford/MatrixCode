#include <exception>
#include <iostream>

#include "TestHarness.h"

void RunControllersTests();
void RunDisplayTopologyTests();
void RunHolidayThemeTests();
void RunImageRevealTests();
void RunIntroTimelineTests();
void RunMessageSchedulerTests();
void RunRainSimulationTests();
void RunSettingsTests();
void RunTokenResolverTests();
void RunUtf8Tests();
void RunCommandLineTests();
void RunSettingsStoreLinuxTests();
void RunImageImportQtTests();
void RunShaderContractTests();

int main() {
  try {
    RunControllersTests();
    RunDisplayTopologyTests();
    RunHolidayThemeTests();
    RunImageRevealTests();
    RunIntroTimelineTests();
    RunMessageSchedulerTests();
    RunRainSimulationTests();
    RunSettingsTests();
    RunTokenResolverTests();
    RunUtf8Tests();
    RunCommandLineTests();
    RunSettingsStoreLinuxTests();
    RunImageImportQtTests();
    RunShaderContractTests();
    std::cout << "MatrixCodeLinuxTests: " << matrixcode::test::assertions
              << " assertions passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "MatrixCodeLinuxTests failed: " << error.what() << '\n';
    return 1;
  }
}
