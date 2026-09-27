#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Tray icon (system notification area). Closing the window hides the app
  // to the tray while the background daemon keeps serving the extension
  // (Bitwarden-style behavior).
  //
  // Returns true when the shell actually accepted the icon. A false return
  // means "do not hide the window": see the WM_CLOSE handler.
  bool CreateTrayIcon();
  void DestroyTrayIcon();
  void ShowTrayMenu();
  void RestoreWindow();
  void MinimizeToTray();

  static constexpr UINT kTrayIconMessage = WM_APP + 1;
  static constexpr UINT kTrayOpenCommand = 1001;
  static constexpr UINT kTrayExitCommand = 1002;

  bool tray_icon_created_ = false;

  // `RegisterWindowMessageW(L"TaskbarCreated")`, broadcast by the shell when
  // Explorer (re)starts. Every tray icon is dropped at that moment, so an app
  // that does not listen loses its icon for the rest of the session - with the
  // window already hidden, the user has no way back.
  UINT taskbar_created_message_ = 0;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
