#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Native messaging host mode (launched by Chrome/Edge). The browser does
  // NOT pass any command-line arguments -- the "args" field of the native
  // messaging manifest is unsupported by Chrome/Edge -- so the mode is
  // detected from startup signals instead:
  //   1. --native-host flag (manual testing),
  //   2. stdin being a pipe (browser launch; reliable for 64-bit launchers),
  //   3. started hidden: Chromium launches native hosts with
  //      STARTF_USESHOWWINDOW + SW_HIDE (start_hidden). This covers browser
  //      launches where the pipe handle is not visible through GetStdHandle
  //      (observed with 32-bit Edge spawning the 64-bit host: the host ran
  //      the UI instead of serving the pipe). A normal double-click launch
  //      is never started hidden.
  // The detected mode is mirrored into an environment variable because
  // Platform.executableArguments is not reliably populated on Flutter
  // Windows.
  STARTUPINFOW si = {sizeof(si)};
  ::GetStartupInfoW(&si);
  const bool started_hidden =
      (si.dwFlags & STARTF_USESHOWWINDOW) != 0 && si.wShowWindow == SW_HIDE;
  const bool is_native_host =
      wcsstr(command_line, L"--native-host") != nullptr ||
      ::GetFileType(::GetStdHandle(STD_INPUT_HANDLE)) == FILE_TYPE_PIPE ||
      started_hidden;
  if (is_native_host) {
    ::SetEnvironmentVariableW(L"EASYPASS_NATIVE_HOST", L"1");
  }

  // Background daemon mode (`easypass.exe --service`, launched by the native
  // host bridge). Windowless: hide the window so no UI ever appears.
  const bool is_service = wcsstr(command_line, L"--service") != nullptr;
  if (is_service) {
    ::SetEnvironmentVariableW(L"EASYPASS_SERVICE", L"1");
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Product name as shown in the title bar / taskbar; the in-app brand lives in
  // the vault sidebar (see lib/features/vault/screens/vault_screen.dart).
  if (!window.Create(L"EasyPass", origin, size)) {
    return EXIT_FAILURE;
  }
  // In native host / daemon mode the Dart code never renders UI; hide the
  // window so nothing pops up. The message loop below still runs, which the
  // Flutter engine needs.
  if (is_native_host || is_service) {
    ::ShowWindow(window.GetHandle(), SW_HIDE);
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
