# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES C CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "easypass")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.easypass.app")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  # Build host uses Clang ≥ 19; the third-party `nlohmann/json.hpp` bundled by
  # flutter_secure_storage_linux emits `-Wdeprecated-literal-operator` warnings
  # (literal-operator names with leading underscore). Keep `-Werror` everywhere
  # except for this bundled header.
  target_compile_options(${TARGET} PRIVATE -Wno-error=deprecated-literal-operator -Wno-deprecated-literal-operator)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# package:sqlite3 is configured with `source: system`, so its Linux runtime
# asset asks the loader for `libsqlite3.so`.  Do not install the Flutter
# plugin under that second name: the plugin is loaded as a Flutter plugin,
# while the Dart worker loads this library through the system-library path.
# Two copies of the same ELF object therefore have two SQLite identities.
#
# Fail fast if the plugin disappears: the bundle below only makes sense as
# long as the plugin (a) still exists, (b) still pulls the sqlite.org source
# tree we re-compile from, and (c) still exposes the `${sqlite3_SOURCE_DIR}`
# that the legacy install path depends on. A silent skip here would ship an
# AppImage that fails on the first `dlopen("libsqlite3.so")` and only
# crashes at runtime, which is exactly the regression described above.
if(TARGET sqlite3_flutter_libs_plugin)
  # Keep the plugin's embedded SQLite private.  Otherwise its exported
  # sqlite3_* symbols can interpose the separately loaded system library.
  # The plugin registration symbol is C++ and keeps the package's existing
  # visibility settings.
  set_target_properties(sqlite3_flutter_libs_plugin PROPERTIES
    C_VISIBILITY_PRESET hidden
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN"
  )

  # sqlite3_flutter_libs uses FetchContent with the upstream sqlite.org
  # archive.  Reuse that exact source tree, but compile it a second time into
  # a distinct shared object.  It is intentionally not a copy, rename, or
  # symlink of the plugin binary: each ELF must own its SQLite mutex/global
  # state because the plugin and Dart worker load them independently.
  include(FetchContent)
  FetchContent_GetProperties(sqlite3)
  if(NOT sqlite3_SOURCE_DIR OR NOT EXISTS "${sqlite3_SOURCE_DIR}/sqlite3.c")
    message(FATAL_ERROR
      "sqlite3_flutter_libs did not provide its sqlite.org source tree")
  endif()

  add_library(easypass_sqlite3 SHARED "${sqlite3_SOURCE_DIR}/sqlite3.c")
  # 这里用 `add_dependencies` 而**不是** `target_link_libraries`，是有意为之：
  #   - 本目标与插件是**两份独立 ELF**（各自持有 SQLite 互斥量/全局态，见上文），
  #     因此两者之间不存在链接依赖。让 `easypass_sqlite3` 去 link 插件会引入
  #     错误的符号解析与 rpath 期望。
  #   - 唯一真实需求是**构建顺序**：插件先被 FetchContent 取源并就绪
  #     （`${sqlite3_SOURCE_DIR}/sqlite3.c`），本目标才能编译。`add_dependencies`
  #     恰好只表达顺序，语义精确。
  #   - `readelf -d` / `ldd` 已确认两者之间没有交叉链接。
  # 结论：不改动构建行为，只在此写清依据。
  set_target_properties(easypass_sqlite3 PROPERTIES
    OUTPUT_NAME sqlite3
    C_VISIBILITY_PRESET default
    BUILD_WITH_INSTALL_RPATH TRUE
    INSTALL_RPATH "$ORIGIN"
  )
  target_compile_features(easypass_sqlite3 PRIVATE c_std_11)
  target_compile_options(easypass_sqlite3 PRIVATE
    "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  # 与 `sqlite3_flutter_libs_plugin` 的
  # `target_compile_definitions` 完全对齐：
  #   - 仅差 `SQLITE_HAVE_LOCALTIME_S`（插件有，独立库原本没有）。
  #   - 本轮对齐：**安全**。`sqlite3.c:25777-25781` 里 `localtime_s(pTm, t)`
  #     分支在 `SQLITE_HAVE_LOCALTIME_R` 被定义后是死代码（preprocessor 把
  #     `#else` 抹掉）—— 即便 glibc 不提供 `localtime_s`，链接时也不会因未
  #     定义符号报错；与插件二进制一致，build 时间戳稳定后可用 `objdump`
  #     看符号表不再有漂移。
  #   - 两份 CMake 现在**除名字外**完全相同；这是一次性对齐，避免
  #     后续升级 sqlite3_flutter_libs 时两边宏分叉的隐患。
  target_compile_definitions(easypass_sqlite3 PRIVATE
    SQLITE_ENABLE_DBSTAT_VTAB
    SQLITE_ENABLE_FTS5
    SQLITE_ENABLE_RTREE
    SQLITE_ENABLE_MATH_FUNCTIONS
    SQLITE_DQS=0
    SQLITE_DEFAULT_MEMSTATUS=0
    SQLITE_TEMP_STORE=2
    SQLITE_MAX_EXPR_DEPTH=0
    SQLITE_STRICT_SUBTYPE=1
    SQLITE_OMIT_AUTHORIZATION
    SQLITE_OMIT_DECLTYPE
    SQLITE_OMIT_DEPRECATED
    SQLITE_OMIT_PROGRESS_CALLBACK
    SQLITE_OMIT_SHARED_CACHE
    SQLITE_OMIT_TCL_VARIABLE
    SQLITE_OMIT_TRACE
    SQLITE_USE_ALLOCA
    SQLITE_ENABLE_SESSION
    SQLITE_ENABLE_PREUPDATE_HOOK
    SQLITE_UNTESTABLE
    SQLITE_HAVE_ISNAN
    SQLITE_HAVE_LOCALTIME_R
    SQLITE_HAVE_LOCALTIME_S
    SQLITE_HAVE_MALLOC_USABLE_SIZE
    SQLITE_HAVE_STRCHRNUL
  )
  install(TARGETS easypass_sqlite3
    LIBRARY DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
else()
  # See the rationale in the comment block immediately above the
  # `if(TARGET sqlite3_flutter_libs_plugin)`.  A silent skip here would
  # ship an AppImage whose first database query fails on a missing
  # `libsqlite3.so`, so we refuse to configure instead.
  message(FATAL_ERROR
    "linux/CMakeLists.txt: sqlite3_flutter_libs_plugin target not found. "
    "The bundled libsqlite3.so can no longer be produced. Either pin "
    "sqlite3_flutter_libs or update this CMake to match the new plugin "
    "layout (the sqlite3_flutter_libs_plugin target is the only source we "
    "trust for the sqlite.org source tree used by `easypass_sqlite3`).")
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Keep the runtime font loader's assets/fonts path identical to Windows. The
# default UI font is loaded by family name from this directory before runApp.
set(FONTS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../assets/fonts")
if(EXISTS "${FONTS_SRC}")
  install(DIRECTORY "${FONTS_SRC}/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/assets/fonts" COMPONENT Runtime)
endif()

# P4 desktop integration: ship the app icon next to the executable so the
# `--install` CLI (`lib/features/desktop_integration/`) can copy it into
# `$XDG_DATA_HOME/icons/hicolor/<size>x<size>/apps/easypass.png` without
# depending on the source checkout. Mirrors the fonts rule above; only the
# Linux bundle/AppImage are affected (windows/ is untouched).
set(ICONS_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../assets/icons")
if(EXISTS "${ICONS_SRC}")
  install(DIRECTORY "${ICONS_SRC}/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/assets/icons" COMPONENT Runtime)
endif()

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
