#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <stdio.h>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayIconId = 1;
constexpr wchar_t kTrayTooltip[] = L"EasyPass";

// Backstop for the `easypass_core.exe` helper commands the tray spawns
// (`--shutdown`, `--lock`). Each CLI is specified to block until it is done and
// to give up on its own after a few seconds, so this only fires when such a
// helper is wedged; it exists so a broken helper cannot freeze the UI thread
// forever.
constexpr DWORD kCoreCommandTimeoutMs = 15000;

// Append one line to %TEMP%\easypass-tray.log.
//
// The tray icon has no user-visible failure mode: when the shell refuses the
// icon the app simply runs without one, and (before this patch) closing the
// window then hid it with no way back. Nothing about that reaches Dart or the
// console, so the decision points are logged here. Diagnostics only -- remove
// once the tray behaves on every target desktop.
void LogTrayLine(const wchar_t* text) {
  wchar_t temp[MAX_PATH] = {0};
  if (GetTempPathW(MAX_PATH, temp) == 0) {
    return;
  }
  wchar_t path[MAX_PATH] = {0};
  if (swprintf_s(path, ARRAYSIZE(path), L"%seasypass-tray.log", temp) < 0) {
    return;
  }
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  SYSTEMTIME now;
  GetLocalTime(&now);
  wchar_t line[512] = {0};
  if (swprintf_s(line, ARRAYSIZE(line), L"%04d-%02d-%02d %02d:%02d:%02d  %ls\r\n",
                 now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute,
                 now.wSecond, text) > 0) {
    DWORD written = 0;
    WriteFile(file, line, static_cast<DWORD>(lstrlenW(line) * sizeof(wchar_t)),
              &written, nullptr);
  }
  CloseHandle(file);
}

// One modal error box, owned by the main window when it still exists (the tray
// menu can be used while the window is hidden to the tray; a null owner keeps
// the box top-level and visible in that case).
void ShowTrayError(HWND owner, const std::wstring& text) {
  MessageBoxW(owner, text.c_str(), L"EasyPass", MB_OK | MB_ICONERROR);
}

// This executable's own directory, without a trailing separator. Empty on
// failure; |error| then receives GetLastError()'s value.
//
// The module path is used on purpose: GetCurrentDirectoryW returns whatever
// directory the process was started from (shell shortcut "Start in", Explorer,
// the browser launcher), which is unrelated to where the core lives.
std::wstring CurrentExecutableDirectory(DWORD* error) {
  wchar_t exe_path[MAX_PATH] = {0};
  const DWORD length =
      GetModuleFileNameW(nullptr, exe_path, ARRAYSIZE(exe_path));
  if (length == 0 || length >= ARRAYSIZE(exe_path)) {
    if (error != nullptr) {
      *error = GetLastError();
    }
    return std::wstring();
  }
  std::wstring directory(exe_path, length);
  const size_t separator = directory.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    if (error != nullptr) {
      *error = ERROR_BAD_PATHNAME;
    }
    return std::wstring();
  }
  directory.erase(separator);
  return directory;
}

// Locate the core service next to this UI, in the order the two known layouts
// use it:
//   1. `<exe dir>\core\easypass_core.exe` -- the installer / release layout.
//      The core lives in a subdirectory because the Dart runtime resolves its
//      bundled libraries as `<exe dir>\..\lib\<name>` (see tool/build_core.ps1).
//   2. `<exe dir>\easypass_core.exe` -- flat development layouts (build\qa,
//      spike_core) where UI and core share one directory.
// Returns an empty string when neither exists (pure UI build).
std::wstring FindCoreExecutable(const std::wstring& exe_dir) {
  const std::wstring candidates[] = {
      exe_dir + L"\\core\\easypass_core.exe",
      exe_dir + L"\\easypass_core.exe",
  };
  for (const std::wstring& candidate : candidates) {
    if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
      return candidate;
    }
  }
  return std::wstring();
}

// Outcome of one `easypass_core.exe <arguments>` run.
struct CoreRunResult {
  // CreateProcessW succeeded.
  bool started = false;
  // The process exited before the timeout backstop fired.
  bool finished = false;
  // Its exit code (1 whenever the run did not complete normally).
  DWORD exit_code = 1;
  // GetLastError() when `started` is false.
  DWORD error = 0;
};

// Run `<core_path> <arguments>` from |exe_dir| with CREATE_NO_WINDOW and wait
// for it to finish.
//
// CREATE_NO_WINDOW matters: the core is a console program, so without it every
// tray command would flash a console window over the UI (or over whatever the
// user is doing when the window is hidden to the tray). The working directory
// is the installation directory so the CLI resolves the same data files as the
// core it talks to.
CoreRunResult RunCoreCommand(const std::wstring& core_path,
                             const std::wstring& exe_dir,
                             const std::wstring& arguments) {
  CoreRunResult result;
  const std::wstring command_line =
      L"\"" + core_path + L"\" " + arguments;
  // CreateProcessW may modify the command line buffer, so it must be writable
  // and NUL-terminated.
  std::vector<wchar_t> command_line_buffer(command_line.begin(),
                                           command_line.end());
  command_line_buffer.push_back(L'\0');

  STARTUPINFOW startup_info = {};
  startup_info.cb = sizeof(startup_info);
  PROCESS_INFORMATION process_info = {};
  if (!CreateProcessW(core_path.c_str(), command_line_buffer.data(), nullptr,
                      nullptr, FALSE, CREATE_NO_WINDOW, nullptr,
                      exe_dir.c_str(), &startup_info, &process_info)) {
    result.error = GetLastError();
    return result;
  }
  result.started = true;
  CloseHandle(process_info.hThread);

  const DWORD wait_result =
      WaitForSingleObject(process_info.hProcess, kCoreCommandTimeoutMs);
  if (wait_result == WAIT_OBJECT_0) {
    result.finished = true;
    DWORD exit_code = 1;
    if (GetExitCodeProcess(process_info.hProcess, &exit_code) != FALSE) {
      result.exit_code = exit_code;
    }
  } else {
    // Timed out (or the wait failed): never leave the helper running.
    TerminateProcess(process_info.hProcess, 1);
    result.exit_code = 1;
  }
  CloseHandle(process_info.hProcess);
  return result;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Explorer broadcasts this when it (re)starts. Every tray icon is dropped at
  // that moment and is NOT re-added automatically, which is the classic
  // "process alive, tray icon gone" state. Register before creating the icon so
  // the handler can restore it.
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");

  CreateTrayIcon();

  return true;
}

void FlutterWindow::OnDestroy() {
  DestroyTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  // Explorer (re)started -> all tray icons were dropped. Re-add ours, otherwise
  // a window that is already hidden stays unreachable for the rest of the
  // session. `tray_icon_created_` must be cleared first: `CreateTrayIcon()`
  // treats it as "already done" and would return immediately.
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_created_ = false;
    LogTrayLine(L"TaskbarCreated: Explorer restarted, re-adding the tray icon");
    if (!CreateTrayIcon() && IsWindowVisible(GetHandle()) == FALSE) {
      // The shell dropped our icon, refused a new one and the window is hidden
      // (the user closed it earlier): restore it, otherwise there is no way
      // left to reach the app.
      RestoreWindow();
    }
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case kTrayIconMessage:
      if (lparam == WM_LBUTTONUP) {
        RestoreWindow();
      } else if (lparam == WM_RBUTTONUP) {
        ShowTrayMenu();
      }
      return 0;
    case WM_COMMAND:
      if (LOWORD(wparam) == kTrayOpenCommand) {
        RestoreWindow();
        return 0;
      }
      if (LOWORD(wparam) == kTrayQuitUiCommand) {
        // Tier 1: lock the vault, then drop this UI. The core keeps running
        // (the browser extension stays served), so the vault must not be left
        // unlocked behind a closed UI. Locking is best effort -- the UI closes
        // either way (see LockVaultBeforeExit).
        LogTrayLine(L"tray: exit UI only (locking the vault first)");
        LockVaultBeforeExit();
        Destroy();
        return 0;
      }
      if (LOWORD(wparam) == kTrayQuitServiceCommand) {
        // Tier 2: stop the core, and only leave when it is really gone.
        // StopCoreService() reports the reason itself and returns false, in
        // which case the UI deliberately stays up for a retry.
        if (StopCoreService()) {
          Destroy();
        }
        return 0;
      }
      break;
    case WM_CLOSE:
      // Bitwarden-style: closing the window hides the app to the tray; the
      // daemon keeps running. Real exit goes through the tray menu.
      //
      // Only hide when the tray icon is really there. When
      // `Shell_NotifyIconW(NIM_ADD)` fails (icon resource missing, shell
      // refused it, Explorer not ready yet) hiding the window locks the user
      // out: the process is alive, the window is gone and there is no icon to
      // click, so the only way out is Task Manager. In that case fall through
      // to the default close (app exits). `CreateTrayIcon()` is retried here,
      // which also covers "the shell was not ready at startup".
      if (tray_icon_created_ || CreateTrayIcon()) {
        LogTrayLine(L"WM_CLOSE: hiding to the tray");
        MinimizeToTray();
        return 0;
      }
      LogTrayLine(L"WM_CLOSE: no tray icon, closing the window for real");
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// ---- tray icon -------------------------------------------------------------

bool FlutterWindow::CreateTrayIcon() {
  if (tray_icon_created_) {
    return true;
  }
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayIconMessage;
  nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid.szTip, kTrayTooltip);
  // Never call NIM_ADD without a valid icon: with NIF_ICON set and hIcon NULL
  // the shell rejects the call, and pretending otherwise would leave WM_CLOSE
  // hiding a window nobody can restore. The BOOL return value is the only
  // reliable "do we have an icon" signal, so it decides whether closing may
  // hide the window. (Note: all comments in windows/runner must stay ASCII --
  // the build has no /utf-8 and cl.exe reads sources in the ANSI codepage.)
  SetLastError(0);
  const BOOL added =
      (nid.hIcon == nullptr) ? FALSE : Shell_NotifyIconW(NIM_ADD, &nid);
  if (nid.hIcon == nullptr || added == FALSE) {
    wchar_t msg[256] = {0};
    swprintf_s(msg, ARRAYSIZE(msg),
               L"FAILED CreateTrayIcon: hIcon=%p NIM_ADD=%ld err=%lu "
               L"cxIcon=%d cyIcon=%d cxSmIcon=%d cySmIcon=%d",
               reinterpret_cast<void*>(nid.hIcon), static_cast<long>(added),
               GetLastError(), GetSystemMetrics(SM_CXICON),
               GetSystemMetrics(SM_CYICON), GetSystemMetrics(SM_CXSMICON),
               GetSystemMetrics(SM_CYSMICON));
    LogTrayLine(msg);
    tray_icon_created_ = false;
    return false;
  }
  LogTrayLine(L"OK CreateTrayIcon: icon registered in the notification area");
  tray_icon_created_ = true;
  return true;
}

void FlutterWindow::DestroyTrayIcon() {
  if (!tray_icon_created_) {
    return;
  }
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  Shell_NotifyIconW(NIM_DELETE, &nid);
  tray_icon_created_ = false;
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"Open EasyPass");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  // Two exits on purpose (docs/core-service-refactor.md section 3.8): the UI
  // and the core have separate lifetimes now, so "leave" and "stop everything"
  // must be two distinct choices. Labels stay English like the rest of this
  // menu (no l10n in the native runner) and must stay ASCII.
  AppendMenuW(menu, MF_STRING, kTrayQuitUiCommand, L"Exit UI Only");
  AppendMenuW(menu, MF_STRING, kTrayQuitServiceCommand,
              L"Exit UI and Stop Service");
  POINT pt;
  GetCursorPos(&pt);
  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN, pt.x, pt.y, 0,
                 GetHandle(), nullptr);
  // MSDN (TrackPopupMenu) requires a PostMessage(WM_NULL) afterwards, otherwise
  // the menu may not dismiss when focus moves away -- the classic "stuck tray
  // menu" bug.
  PostMessageW(GetHandle(), WM_NULL, 0, 0);
  DestroyMenu(menu);
}

void FlutterWindow::RestoreWindow() {
  ShowWindow(GetHandle(), SW_SHOW);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::MinimizeToTray() {
  ShowWindow(GetHandle(), SW_HIDE);
  // Nothing to notify when there is no icon in the notification area. The call
  // sites already guarantee that, this is belt and braces.
  if (!tray_icon_created_) {
    return;
  }
  // Notify the user once, with the restore hint.
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_INFO;
  wcscpy_s(nid.szInfoTitle, L"EasyPass");
  wcscpy_s(nid.szInfo,
           L"EasyPass is still running in the background. "
           L"Click the tray icon to restore it.");
  nid.dwInfoFlags = NIIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &nid);
}

// ---- core commands ---------------------------------------------------------

bool FlutterWindow::StopCoreService() {
  DWORD dir_error = 0;
  const std::wstring exe_dir = CurrentExecutableDirectory(&dir_error);
  if (exe_dir.empty()) {
    wchar_t detail[256] = {0};
    swprintf_s(detail, ARRAYSIZE(detail),
               L"Could not determine the EasyPass installation directory "
               L"(GetModuleFileNameW, error %lu).\n\nThe service was not "
               L"stopped and this window stays open.",
               dir_error);
    ShowTrayError(GetHandle(), detail);
    return false;
  }

  const std::wstring core_path = FindCoreExecutable(exe_dir);
  if (core_path.empty()) {
    ShowTrayError(GetHandle(),
                  L"The EasyPass background service was not found at:\n" +
                      exe_dir + L"\\core\\easypass_core.exe\n" + exe_dir +
                      L"\\easypass_core.exe\n\nThis window stays open. "
                      L"Reinstall EasyPass or start it from the installation "
                      L"directory.");
    return false;
  }

  const CoreRunResult result = RunCoreCommand(core_path, exe_dir, L"--shutdown");
  if (!result.started) {
    wchar_t detail[512] = {0};
    swprintf_s(detail, ARRAYSIZE(detail),
               L"Could not start the EasyPass background service shutdown:\n"
               L"%ls\n\nWindows error %lu. This window stays open.",
               core_path.c_str(), result.error);
    ShowTrayError(GetHandle(), detail);
    return false;
  }

  if (!result.finished || result.exit_code != 0) {
    wchar_t detail[512] = {0};
    if (result.finished) {
      swprintf_s(detail, ARRAYSIZE(detail),
                 L"The EasyPass background service did not stop (exit code "
                 L"%lu).\n\nThe service may still be running; this window "
                 L"stays open so you can retry or check the log.",
                 result.exit_code);
    } else {
      swprintf_s(detail, ARRAYSIZE(detail),
                 L"The EasyPass background service did not stop within %lu "
                 L"seconds.\n\nThe service may still be running; this window "
                 L"stays open so you can retry.",
                 kCoreCommandTimeoutMs / 1000);
    }
    ShowTrayError(GetHandle(), detail);
    LogTrayLine(L"FAILED StopCoreService: the core shutdown helper did not "
                L"report success");
    return false;
  }

  LogTrayLine(L"OK StopCoreService: the core is gone, exiting the UI");
  return true;
}

void FlutterWindow::LockVaultBeforeExit() {
  // "Exit UI Only" leaves the core (and therefore the vault) running for the
  // browser extension, so the vault has to be locked before this UI goes away
  // -- otherwise closing the window would leave an unlocked vault behind for
  // whoever sits down at the machine next.
  //
  // Best effort by design: any failure is reported and the UI quits anyway. A
  // failed lock must not trap the user inside the window (the same reasoning as
  // the tray-vs-Task-Manager fallback in WM_CLOSE).
  DWORD dir_error = 0;
  const std::wstring exe_dir = CurrentExecutableDirectory(&dir_error);
  if (exe_dir.empty()) {
    wchar_t detail[256] = {0};
    swprintf_s(detail, ARRAYSIZE(detail),
               L"Could not lock the vault before closing the UI.\n\nThe "
               L"EasyPass installation directory could not be determined "
               L"(GetModuleFileNameW, error %lu). The vault may still be "
               L"unlocked.",
               dir_error);
    ShowTrayError(GetHandle(), detail);
    return;
  }

  const std::wstring core_path = FindCoreExecutable(exe_dir);
  if (core_path.empty()) {
    // Development layout with no core next to the UI (e.g. `flutter run`):
    // there is nothing to lock, and this is not an error worth a dialog.
    LogTrayLine(L"tray: no core executable found; skipping the vault lock");
    return;
  }

  const CoreRunResult result = RunCoreCommand(core_path, exe_dir, L"--lock");
  if (!result.started) {
    wchar_t detail[512] = {0};
    swprintf_s(detail, ARRAYSIZE(detail),
               L"Could not lock the vault before closing the UI.\n\n%ls "
               L"--lock could not be started (Windows error %lu). The vault "
               L"may still be unlocked.",
               core_path.c_str(), result.error);
    ShowTrayError(GetHandle(), detail);
    return;
  }

  if (!result.finished || result.exit_code != 0) {
    wchar_t detail[512] = {0};
    if (result.finished) {
      swprintf_s(detail, ARRAYSIZE(detail),
                 L"Could not lock the vault before closing the UI.\n\n"
                 L"easypass_core --lock exited with code %lu. The vault may "
                 L"still be unlocked.",
                 result.exit_code);
    } else {
      swprintf_s(detail, ARRAYSIZE(detail),
                 L"Could not lock the vault before closing the UI.\n\n"
                 L"easypass_core --lock did not finish within %lu seconds. The "
                 L"vault may still be unlocked.",
                 kCoreCommandTimeoutMs / 1000);
    }
    ShowTrayError(GetHandle(), detail);
    LogTrayLine(L"FAILED LockVaultBeforeExit: the lock helper did not report "
                L"success");
    return;
  }

  LogTrayLine(L"OK LockVaultBeforeExit: the vault is locked, exiting the UI");
}
