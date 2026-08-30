cmake_minimum_required(VERSION 3.29)

project(MatrixCodeWindows VERSION 0.1.0 LANGUAGES CXX RC)

if(NOT WIN32)
  message(FATAL_ERROR "MatrixCodeWindows targets Windows 10/11 only")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

set(MATRIXCODE_VERSION "${PROJECT_VERSION}" CACHE STRING "Matrix Code release version")
set(MATRIXCODE_PUBLISHER "MatrixCode Project" CACHE STRING "PE Publisher display name")
if(MATRIXCODE_VERSION MATCHES "^([0-9]+)\\.([0-9]+)\\.([0-9]+)(\\.([0-9]+))?$")
  set(MATRIXCODE_VERSION_MAJOR "${CMAKE_MATCH_1}")
  set(MATRIXCODE_VERSION_MINOR "${CMAKE_MATCH_2}")
  set(MATRIXCODE_VERSION_PATCH "${CMAKE_MATCH_3}")
  if(CMAKE_MATCH_5)
    set(MATRIXCODE_VERSION_BUILD "${CMAKE_MATCH_5}")
  else()
    set(MATRIXCODE_VERSION_BUILD "0")
  endif()
else()
  message(FATAL_ERROR "MATRIXCODE_VERSION must be numeric MAJOR.MINOR.PATCH[.BUILD]")
endif()

include(CTest)
include(cmake/CompilerOptions.cmake)

add_library(MatrixCodeCore STATIC
  src/core/Controllers.cpp
  src/core/DisplayTopology.cpp
  src/core/GlyphSet.cpp
  src/core/HolidayResolver.cpp
  src/core/ImageReveal.cpp
  src/core/IntroTimeline.cpp
  src/core/Json.cpp
  src/core/MessageScheduler.cpp
  src/core/RainSimulation.cpp
  src/core/Settings.cpp
  src/core/TokenResolver.cpp
  src/core/Utf8.cpp
)
target_include_directories(MatrixCodeCore PUBLIC include)
matrixcode_target_options(MatrixCodeCore)

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/shaders/MatrixCode.hlsl" MATRIXCODE_SHADER_SOURCE)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbeddedShader.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/EmbeddedShader.h"
  @ONLY
)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/Version.h.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/Version.h"
  @ONLY
)

add_library(MatrixCodeRenderD3D11 STATIC
  src/render/D3D11Renderer.cpp
  src/render/GlyphAtlas.cpp
  src/render/IntroOverlay.cpp
)
target_include_directories(MatrixCodeRenderD3D11
  PUBLIC include
  PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
target_link_libraries(MatrixCodeRenderD3D11
  PUBLIC MatrixCodeCore
  PRIVATE d3d11 dxgi d3dcompiler d2d1 dwrite windowscodecs ole32
)
matrixcode_target_options(MatrixCodeRenderD3D11)

add_library(MatrixCodeWin32 STATIC
  src/platform/DocumentEditor.cpp
  src/platform/ScreenSaverArgs.cpp
  src/platform/ImageImportWin32.cpp
  src/platform/SettingsStoreWin32.cpp
  src/platform/SettingsWindow.cpp
  src/platform/Win32Utf.cpp
  src/platform/Win32Host.cpp
)
target_include_directories(MatrixCodeWin32
  PUBLIC include
  PRIVATE resources "${CMAKE_CURRENT_BINARY_DIR}/generated"
)
target_link_libraries(MatrixCodeWin32
  PUBLIC MatrixCodeCore MatrixCodeRenderD3D11
  PRIVATE advapi32 bcrypt comctl32 comdlg32 dwmapi ole32 shcore shell32 userenv secur32 windowscodecs
)
matrixcode_target_options(MatrixCodeWin32)

configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/resources/MatrixCode.rc.in"
  "${CMAKE_CURRENT_BINARY_DIR}/generated/MatrixCode.rc"
  @ONLY
)
set(MATRIXCODE_COMMON_RESOURCES
  "${CMAKE_CURRENT_BINARY_DIR}/generated/MatrixCode.rc"
)

add_executable(MatrixCodeApp WIN32 app/Main.cpp ${MATRIXCODE_COMMON_RESOURCES})
set_target_properties(MatrixCodeApp PROPERTIES OUTPUT_NAME "MatrixCode")
target_link_libraries(MatrixCodeApp PRIVATE MatrixCodeWin32)
target_link_options(MatrixCodeApp PRIVATE /MANIFEST:NO)
matrixcode_target_options(MatrixCodeApp)

add_executable(MatrixCodeScreenSaver WIN32 screensaver/Main.cpp ${MATRIXCODE_COMMON_RESOURCES})
set_target_properties(MatrixCodeScreenSaver PROPERTIES
  OUTPUT_NAME "Matrix Code"
  SUFFIX ".scr"
)
target_link_libraries(MatrixCodeScreenSaver PRIVATE MatrixCodeWin32)
target_compile_definitions(MatrixCodeScreenSaver PRIVATE MATRIXCODE_SCREENSAVER=1)
target_link_options(MatrixCodeScreenSaver PRIVATE /MANIFEST:NO)
matrixcode_target_options(MatrixCodeScreenSaver)

add_executable(MatrixCodeRenderCapture tools/RenderCapture.cpp ${MATRIXCODE_COMMON_RESOURCES})
target_link_libraries(MatrixCodeRenderCapture PRIVATE MatrixCodeWin32)
target_link_options(MatrixCodeRenderCapture PRIVATE /MANIFEST:NO)
matrixcode_target_options(MatrixCodeRenderCapture)

if(BUILD_TESTING)
  add_executable(MatrixCodeNativeTests
    tests/TestMain.cpp
    tests/ControllersTests.cpp
    tests/DisplayTopologyTests.cpp
    tests/HolidayThemeTests.cpp
    tests/ImageRevealTests.cpp
    tests/ImageImportTests.cpp
    tests/IntroTimelineTests.cpp
    tests/MessageSchedulerTests.cpp
    tests/RainSimulationTests.cpp
    tests/ScreenSaverArgsTests.cpp
    tests/SettingsTests.cpp
    tests/TokenResolverTests.cpp
    tests/Utf8Tests.cpp
    tests/Win32UtfTests.cpp
  )
  target_link_libraries(MatrixCodeNativeTests PRIVATE MatrixCodeWin32)
  target_compile_definitions(MatrixCodeNativeTests PRIVATE MATRIXCODE_SOURCE_DIR=L"${CMAKE_CURRENT_SOURCE_DIR}")
  matrixcode_target_options(MatrixCodeNativeTests)
  add_test(NAME MatrixCodeNativeTests COMMAND MatrixCodeNativeTests)
endif()

install(TARGETS MatrixCodeApp MatrixCodeScreenSaver
  RUNTIME DESTINATION .
)
install(FILES README.md LICENSES.md DESTINATION .)
install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../../LICENSE" DESTINATION . RENAME LICENSE.txt)
