cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Compile the x86 native messaging host bridge next to the app binary.
# Must live in this directory: add_custom_command(TARGET ...) requires
# the target to be created here.
# Path to the x86 native messaging host bridge sources
# (repo root: browser_extension/native_host).
set(EASYPASS_BRIDGE_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/../../browser_extension/native_host")

add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND cmd /c call "${EASYPASS_BRIDGE_DIR}/build_bridge.bat"
          "$<TARGET_FILE_DIR:${BINARY_NAME}>"
  COMMENT "Building EasyPass native messaging host bridge (x86)"
  VERBATIM
)

# Ship the app-local x64 MSVC runtime next to the executable.
# The installer collects these DLLs from the build output directory, but nothing
# in the build produces them (windows/CMakeLists.txt installs the app, ICU data,
# plugin DLLs, fonts and assets only), so packaging used to fail with
# "Source file ... does not exist". Keep this hook: this file is tracked in git.
# installer/easypass_setup.iss also has a system-directory fallback.
add_custom_command(TARGET ${BINARY_NAME} POST_BUILD
  COMMAND cmd /c call
          "${CMAKE_CURRENT_SOURCE_DIR}/../../installer/copy_vc_runtime.bat"
          "$<TARGET_FILE_DIR:${BINARY_NAME}>"
  COMMENT "Copying MSVC runtime DLLs (msvcp140 / vcruntime140*)"
  VERBATIM
)
