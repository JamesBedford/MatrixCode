#pragma once

class QApplication;

namespace matrixcode::platform {
struct CommandLineOptions;
}

namespace matrixcode::app {

/** Run the requested native surface until all render windows have closed. */
[[nodiscard]] int RunMatrixCodeHost(
  QApplication& application,
  const platform::CommandLineOptions& options);

}  // namespace matrixcode::app
