cmake_minimum_required(VERSION 3.28)

project(MatrixCode VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

include(CTest)
include(GNUInstallDirs)

find_package(Qt6 6.4 REQUIRED COMPONENTS
  Core
  Gui
  OpenGL
  OpenGLWidgets
  Widgets
)
find_package(X11 REQUIRED COMPONENTS xcb)

set(MATRIXCODE_REPOSITORY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../..")
set(MATRIXCODE_WINDOWS_ROOT "${MATRIXCODE_REPOSITORY_ROOT}/windows/MatrixCode")

function(matrixcode_target_options target)
  if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:CXX>:-Wall>
      $<$<COMPILE_LANGUAGE:CXX>:-Wextra>
      $<$<COMPILE_LANGUAGE:CXX>:-Wpedantic>
      $<$<COMPILE_LANGUAGE:CXX>:-Werror>
      $<$<COMPILE_LANGUAGE:CXX>:-ffp-contract=off>
      $<$<COMPILE_LANGUAGE:CXX>:-fno-fast-math>
    )
  endif()
endfunction()

add_library(MatrixCodeCore STATIC
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/Controllers.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/DisplayTopology.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/GlyphSet.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/HolidayResolver.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/ImageReveal.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/IntroTimeline.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/Json.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/MessageScheduler.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/RainSimulation.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/Settings.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/TokenResolver.cpp"
  "${MATRIXCODE_WINDOWS_ROOT}/src/core/Utf8.cpp"
)
target_include_directories(MatrixCodeCore PUBLIC
  "${MATRIXCODE_WINDOWS_ROOT}/include"
)
matrixcode_target_options(MatrixCodeCore)

add_library(MatrixCodePlatformLinux STATIC
  src/platform/CommandLine.cpp
  src/platform/ImageImportQt.cpp
  src/platform/SettingsStoreLinux.cpp
  src/platform/X11Window.cpp
)
target_include_directories(MatrixCodePlatformLinux PUBLIC
  include
  "${X11_xcb_INCLUDE_PATH}"
)
target_link_libraries(MatrixCodePlatformLinux
  PUBLIC
    MatrixCodeCore
    Qt6::Core
    Qt6::Gui
    X11::X11
)
matrixcode_target_options(MatrixCodePlatformLinux)

add_library(MatrixCodeRenderGL STATIC
  src/render/GlyphAtlas.cpp
  src/render/OpenGLRenderer.cpp
  src/render/TextOverlay.cpp
)
target_include_directories(MatrixCodeRenderGL PUBLIC include)
target_compile_definitions(MatrixCodeRenderGL PRIVATE
  MATRIXCODE_LINUX_SHADER_DIR="${CMAKE_CURRENT_SOURCE_DIR}/shaders"
)
target_link_libraries(MatrixCodeRenderGL
  PUBLIC
    MatrixCodeCore
    Qt6::Core
    Qt6::Gui
    Qt6::OpenGL
)
matrixcode_target_options(MatrixCodeRenderGL)

add_library(MatrixCodeUiQt STATIC
  src/ui/SettingsDialog.cpp
)
target_include_directories(MatrixCodeUiQt PUBLIC include)
target_link_libraries(MatrixCodeUiQt
  PUBLIC
    MatrixCodeCore
    MatrixCodePlatformLinux
    Qt6::Widgets
)
matrixcode_target_options(MatrixCodeUiQt)

add_executable(MatrixCode
  app/Main.cpp
  src/app/MatrixCodeHost.cpp
  resources/matrixcode.qrc
)
target_include_directories(MatrixCode PRIVATE include)
target_compile_definitions(MatrixCode PRIVATE
  MATRIXCODE_VERSION_STRING="${PROJECT_VERSION}"
)
target_link_libraries(MatrixCode PRIVATE
  MatrixCodeCore
  MatrixCodePlatformLinux
  MatrixCodeRenderGL
  MatrixCodeUiQt
  Qt6::Core
  Qt6::Gui
  Qt6::OpenGL
  Qt6::OpenGLWidgets
  Qt6::Widgets
)
matrixcode_target_options(MatrixCode)

install(TARGETS MatrixCode
  RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}"
)

if(BUILD_TESTING)
  add_executable(MatrixCodeLinuxTests
    tests/CoreTestMain.cpp
    tests/CommandLineTests.cpp
    tests/ImageImportQtTests.cpp
    tests/ShaderContractTests.cpp
    tests/SettingsStoreLinuxTests.cpp
    tests/X11WindowTests.cpp
    "${MATRIXCODE_WINDOWS_ROOT}/tests/ControllersTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/DisplayTopologyTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/HolidayThemeTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/ImageRevealTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/IntroTimelineTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/MessageSchedulerTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/RainSimulationTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/SettingsTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/TokenResolverTests.cpp"
    "${MATRIXCODE_WINDOWS_ROOT}/tests/Utf8Tests.cpp"
  )
  target_include_directories(MatrixCodeLinuxTests PRIVATE
    include
    tests
    "${MATRIXCODE_WINDOWS_ROOT}/tests"
  )
  target_link_libraries(MatrixCodeLinuxTests PRIVATE
    MatrixCodeCore
    MatrixCodePlatformLinux
    Qt6::Core
    Qt6::Gui
  )
  target_compile_definitions(MatrixCodeLinuxTests PRIVATE
    MATRIXCODE_LINUX_SHADER_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/shaders"
    MATRIXCODE_LINUX_RESOURCE_FILE="${CMAKE_CURRENT_SOURCE_DIR}/resources/matrixcode.qrc"
  )
  matrixcode_target_options(MatrixCodeLinuxTests)
  add_test(NAME MatrixCodeLinuxTests COMMAND MatrixCodeLinuxTests)
  add_test(
    NAME MatrixCodeXScreenSaverLauncherTests
    COMMAND sh
      "${CMAKE_CURRENT_SOURCE_DIR}/tests/XScreenSaverLauncherTests.sh"
      "${CMAKE_CURRENT_SOURCE_DIR}/resources/xscreensaver/matrixcode"
  )
endif()

install(FILES
  README.md
  LICENSES.md
  "${MATRIXCODE_REPOSITORY_ROOT}/LICENSE"
  DESTINATION "${CMAKE_INSTALL_DATADIR}/doc/matrixcode"
)

install(FILES resources/io.github.matrixcode.MatrixCode.desktop
  DESTINATION "${CMAKE_INSTALL_DATADIR}/applications"
)
install(FILES resources/io.github.matrixcode.MatrixCode.metainfo.xml
  DESTINATION "${CMAKE_INSTALL_DATADIR}/metainfo"
)
install(FILES resources/icons/hicolor/scalable/apps/io.github.matrixcode.MatrixCode.svg
  DESTINATION "${CMAKE_INSTALL_DATADIR}/icons/hicolor/scalable/apps"
)
install(FILES resources/xscreensaver/matrixcode.xml
  DESTINATION "${CMAKE_INSTALL_DATADIR}/xscreensaver/config"
)
install(PROGRAMS resources/xscreensaver/matrixcode
  DESTINATION "${CMAKE_INSTALL_LIBEXECDIR}/xscreensaver"
)

set(CPACK_GENERATOR DEB)
set(CPACK_PACKAGE_NAME matrixcode)
set(CPACK_PACKAGE_VENDOR "MatrixCode Project")
set(CPACK_PACKAGE_CONTACT "James Bedford <james_bedford@me.com>")
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY
  "GPU-accelerated native Matrix digital rain for Ubuntu Linux")
set(CPACK_PACKAGE_HOMEPAGE_URL "https://github.com/JamesBedford/MatrixCode")
set(CPACK_PACKAGE_VERSION "${PROJECT_VERSION}")
set(CPACK_RESOURCE_FILE_LICENSE "${MATRIXCODE_REPOSITORY_ROOT}/LICENSE")
set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
set(CPACK_DEBIAN_PACKAGE_SECTION graphics)
set(CPACK_DEBIAN_PACKAGE_PRIORITY optional)
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libqt6openglwidgets6 (>= 6.4.0)")
set(CPACK_DEBIAN_PACKAGE_RECOMMENDS "qt6-image-formats-plugins, fonts-noto-cjk")
set(CPACK_DEBIAN_PACKAGE_SUGGESTS "xscreensaver")
set(CPACK_INSTALL_DEFAULT_DIRECTORY_PERMISSIONS
  OWNER_READ OWNER_WRITE OWNER_EXECUTE
  GROUP_READ GROUP_EXECUTE
  WORLD_READ WORLD_EXECUTE
)
set(CPACK_STRIP_FILES TRUE)
include(CPack)
