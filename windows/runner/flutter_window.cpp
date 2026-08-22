#include "flutter_window.h"

#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

constexpr UINT kTrayIconId = 1;
constexpr wchar_t kTrayTooltip[] = L"EasyPass";

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
      MinimizeToTray();
      return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

// ---- tray icon -------------------------------------------------------------

void FlutterWindow::CreateTrayIcon() {
  if (tray_icon_created_) {
    return;
  }
  NOTIFYICONDATAW nid = {};
  nid.cbSize = sizeof(nid);
  nid.hWnd = GetHandle();
  nid.uID = kTrayIconId;
  nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  nid.uCallbackMessage = kTrayIconMessage;
  nid.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(nid.szTip, kTrayTooltip);
  Shell_NotifyIconW(NIM_ADD, &nid);
  tray_icon_created_ = true;
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
  DestroyMenu(menu);
}

void FlutterWindow::RestoreWindow() {
  ShowWindow(GetHandle(), SW_SHOW);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::MinimizeToTray() {
  ShowWindow(GetHandle(), SW_HIDE);
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
