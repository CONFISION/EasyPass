#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <stdio.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayIconId = 1;
constexpr wchar_t kTrayTooltip[] = L"EasyPass";

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
      if (LOWORD(wparam) == kTrayExitCommand) {
        Destroy();
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
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"Exit");
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
