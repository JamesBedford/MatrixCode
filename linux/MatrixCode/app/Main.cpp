#include <algorithm>

#include <QApplication>
#include <QCoreApplication>
#include <QMessageBox>
#include <QSurfaceFormat>
#include <QTextStream>

#include "matrixcode/app/MatrixCodeHost.h"
#include "matrixcode/platform/CommandLine.h"

namespace {

bool RequestsSoftwareRendering(const int argc, char* argv[]) {
  for (int index = 1; index < argc; ++index) {
    if (QString::fromLocal8Bit(argv[index]) == QStringLiteral("--software")) return true;
  }
  return false;
}

}  // namespace

int main(int argc, char* argv[]) {
  QCoreApplication::setOrganizationName(QStringLiteral("MatrixCode"));
  QCoreApplication::setOrganizationDomain(QStringLiteral("matrixcode.app"));
  QCoreApplication::setApplicationName(QStringLiteral("MatrixCode"));
  QCoreApplication::setApplicationVersion(QString::fromLatin1(MATRIXCODE_VERSION_STRING));
  QApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
  if (RequestsSoftwareRendering(argc, argv)) {
    qputenv("LIBGL_ALWAYS_SOFTWARE", "1");
    QApplication::setAttribute(Qt::AA_UseSoftwareOpenGL);
  }

  QSurfaceFormat format;
  format.setRenderableType(QSurfaceFormat::OpenGL);
  format.setVersion(3, 3);
  format.setProfile(QSurfaceFormat::CoreProfile);
  format.setDepthBufferSize(0);
  format.setStencilBufferSize(0);
  format.setSwapBehavior(QSurfaceFormat::DoubleBuffer);
  QSurfaceFormat::setDefaultFormat(format);

  QApplication application(argc, argv);
  application.setApplicationDisplayName(QObject::tr("Matrix Code"));
  application.setDesktopFileName(QStringLiteral("io.github.matrixcode.MatrixCode"));
  application.setQuitOnLastWindowClosed(true);

  const auto parsed = matrixcode::platform::ParseCommandLine(application.arguments());
  if (!parsed.options.has_value()) {
    QMessageBox::critical(nullptr, QObject::tr("Matrix Code"),
      parsed.error + QStringLiteral("\n\n") + matrixcode::platform::CommandLineHelp());
    return 2;
  }
  if (parsed.options->mode == matrixcode::platform::LaunchMode::Help) {
    QTextStream(stdout) << matrixcode::platform::CommandLineHelp();
    return 0;
  }
  return matrixcode::app::RunMatrixCodeHost(application, *parsed.options);
}
