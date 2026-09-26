cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "easypass_tray.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# libayatana-appindicator supplies the StatusNotifierItem tray icon used by
# `easypass_tray.cc`. Prefer the maintained ayatana fork and fall back to the
# older `appindicator3-0.1` pkg-config name; the include path differs, hence
# the HAVE_AYATANA define.
pkg_check_modules(APPINDICATOR IMPORTED_TARGET ayatana-appindicator3-0.1)
if(APPINDICATOR_FOUND)
  add_definitions(-DHAVE_AYATANA)
else()
  pkg_check_modules(APPINDICATOR REQUIRED IMPORTED_TARGET appindicator3-0.1)
endif()
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::APPINDICATOR)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
