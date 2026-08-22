cmake_minimum_required(VERSION 3.14)
project(easypass_native_host LANGUAGES CXX)

# The EasyPass native messaging host bridge: an x86 console program that
# forwards the browser's stdio pipe to the background daemon over loopback
# TCP. It must be compiled for x86 so 32-bit browsers (e.g. Edge x86) inherit
# its stdio handles reliably; the parent Flutter project builds x64, so this
# is configured as a separate Win32 CMake project (see windows/CMakeLists.txt,
# ExternalProject_Add with -DCMAKE_GENERATOR_PLATFORM=Win32).

add_executable(easypass_native_host easypass_native_host.cpp)
target_link_libraries(easypass_native_host PRIVATE ws2_32)
target_compile_features(easypass_native_host PRIVATE cxx_std_17)

if(MSVC)
  # Static CRT so the bridge has no runtime DLL dependencies (it is a tiny
  # console binary shipped next to easypass.exe).
  set_target_properties(easypass_native_host PROPERTIES
    MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
  target_compile_options(easypass_native_host PRIVATE /W4 /EHsc /D_CRT_SECURE_NO_WARNINGS)
endif()
