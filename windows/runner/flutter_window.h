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

  // Tray "Exit UI and Stop Service": run `easypass_core.exe --shutdown` from
  // this executable's own directory and wait for that CLI to finish.
  //
  // Returns true only when the core CLI exited 0, which covers both "the core
  // was stopped" and "no core was running" (see the core CLI contract:
  // --shutdown returns 0 in either case, 1 on timeout/failure). On failure the
  // reason is reported in a message box and false is returned, so the caller
  // keeps this UI alive and the user can retry.
  bool StopCoreService();

  // Lock the vault through the core: run `easypass_core.exe --lock` and wait
  // for it (15 s backstop).
  //
  // Shared by the two paths that leave the UI invisible while the core keeps
  // running: close-to-tray (WM_CLOSE) and the tray's "Exit UI Only". Reopening
  // the window must ask for the master password again, so the lock has to
  // happen here and not on the core's idle timeout.
  //
  // Best effort by contract -- the caller hides/closes either way. A failed
  // lock opens a message box; a missing core (pure UI development layout) is
  // skipped silently.
  void LockVault();

  static constexpr UINT kTrayIconMessage = WM_APP + 1;
  static constexpr UINT kTrayOpenCommand = 1001;
  // Ends this UI process only, after locking the vault. The background core
  // keeps running, so the browser extension stays served.
  static constexpr UINT kTrayQuitUiCommand = 1002;
  // Stops the background core first and only then ends this UI process.
  static constexpr UINT kTrayQuitServiceCommand = 1003;

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
