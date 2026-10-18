#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <stdio.h>

#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

// ---- single instance gate --------------------------------------------------
//
// The UI owns the window AND the tray icon (the core service is a separate,
// windowless process), so a second UI process would mean two tray icons, two
// windows onto the same vault and two "Exit UI Only" entries. This gate makes a
// second launch raise the running window instead.
//
// `Local\` scopes the name to the current logon session: another user (or an
// RDP session) must not be treated as "the same instance", because the window
// and the tray icon are per-session anyway.
constexpr wchar_t kSingleInstanceMutexName[] = L"Local\\EasyPass.UI";

// The runner's window class (win32_window.cpp, kWindowClassName) and the title
// passed to `window.Create(L"EasyPass", ...)` below. The pair identifies our own
// window: the title is never changed at runtime (there is no
// SystemChrome.setApplicationSwitcherDescription anywhere in lib/).
constexpr wchar_t kRunnerWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kRunnerWindowTitle[] = L"EasyPass";

// True when any argument starts with `--`, i.e. this is a CLI invocation.
//
// CLI switches must never be answered with "the UI is already running": they are
// short-lived console commands (--install, --uninstall, --desktop-status,
// --install-browser-host, --uninstall-browser-host, --browser-host-status) that
// have to run while the UI is open. Gating them would make them exit silently
// and look like they did nothing. The argument list comes from
// GetCommandLineArguments(), which drops the program name, so a path like
// C:\my--dir\easypass.exe cannot be mistaken for a switch.
bool HasCommandLineSwitch(const std::vector<std::string>& arguments) {
  for (const std::string& argument : arguments) {
    if (argument.compare(0, 2, "--") == 0) {
      return true;
    }
  }
  return false;
}

// Raise the window of the instance that already holds the mutex.
//
// Waits up to ~2 s: two quick launches race with the first process's
// CreateWindow, and the user double-clicked the icon precisely to get the
// window -- giving up instantly would look like "nothing happened".
bool ActivateExistingInstance() {
  constexpr int kAttempts = 20;
  constexpr DWORD kDelayMs = 100;
  for (int attempt = 0; attempt < kAttempts; ++attempt) {
    HWND window = ::FindWindowW(kRunnerWindowClass, kRunnerWindowTitle);
    if (window != nullptr) {
      // SW_RESTORE also un-hides a window that was closed to the tray
      // (WM_CLOSE hides it instead of destroying it) and de-minimizes one.
      ::ShowWindow(window, SW_RESTORE);
      ::SetForegroundWindow(window);
      return true;
    }
    ::Sleep(kDelayMs);
  }
  return false;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Command line without the program name; used by the single-instance gate
  // below and handed to the Dart entrypoint further down.
  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // Single instance gate. `CreateMutexW` returns a handle in both cases; the
  // last error is the only "someone got here first" signal, and it has to be
  // cleared first because CreateMutexW does not reset it when the mutex is new.
  //
  // The handle is deliberately NEVER closed: it must live exactly as long as
  // this process. Closing it early (or using a scope guard) would make the next
  // launch believe no instance is running and start a second one.
  HANDLE single_instance_mutex = nullptr;
  if (!HasCommandLineSwitch(command_line_arguments)) {
    ::SetLastError(ERROR_SUCCESS);
    single_instance_mutex =
        ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutexName);
    // Read the error right away: anything in between (formatting, other API
    // calls) may overwrite it.
    const DWORD create_error = ::GetLastError();
    if (single_instance_mutex == nullptr) {
      // Fail open. A broken gate must never make the app impossible to open:
      // two instances are recoverable (close one), a launch that silently does
      // nothing is not. stderr is only visible when a console is attached
      // (flutter run / debugger), which is exactly where this is useful.
      fprintf(stderr,
              "easypass: single-instance gate unavailable "
              "(CreateMutexW error %lu); continuing without it\n",
              static_cast<unsigned long>(create_error));
    } else if (create_error == ERROR_ALREADY_EXISTS) {
      // Another UI process is already running: raise its window and leave
      // WITHOUT creating a window (and therefore without a tray icon).
      if (!ActivateExistingInstance()) {
        fprintf(stderr,
                "easypass: another instance holds the single-instance mutex "
                "but its window was not found; exiting\n");
      }
      return EXIT_SUCCESS;
    }
  }

  // 3.0.0: the UI binary has exactly one mode. The old `--native-host` (browser
  // stdio host) and `--service` (windowless in-process daemon) modes moved into
  // the core service -- `easypass_core --bridge` and `easypass_core --serve`
  // (see bin/easypass_core.dart) -- so the mode detection that used to live
  // here (flag sniffing, pipe-stdin / started-hidden heuristics, the
  // EASYPASS_NATIVE_HOST / EASYPASS_SERVICE environment variables and the
  // "keep the window hidden" path) is gone. Passing either switch to
  // easypass.exe now simply starts the normal UI, which is harmless.

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // `command_line_arguments` was read before the single-instance gate and is
  // moved into the project here.
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // Product name as shown in the title bar / taskbar; the in-app brand lives in
  // the vault sidebar (see lib/features/vault/screens/vault_screen.dart).
  if (!window.Create(L"EasyPass", origin, size)) {
    return EXIT_FAILURE;
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
