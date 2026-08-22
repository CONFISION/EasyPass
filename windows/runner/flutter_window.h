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
  void CreateTrayIcon();
  void DestroyTrayIcon();
  void ShowTrayMenu();
  void RestoreWindow();
  void MinimizeToTray();

  static constexpr UINT kTrayIconMessage = WM_APP + 1;
  static constexpr UINT kTrayOpenCommand = 1001;
  static constexpr UINT kTrayExitCommand = 1002;

  bool tray_icon_created_ = false;

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
