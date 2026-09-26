// Non-Linux / non-Windows desktop-tray stub (P3.1).
//
// macOS and any future target falls through here. We deliberately do not
// wire `tray_manager` on macOS yet — Linux parity is the only ask in P3,
// and the existing Flutter macOS template doesn't ship a tray. Returns
// `inactive` so callers know there is no Bitwarden-style close-to-hide on
// these platforms.

import 'desktop_tray.dart';

DesktopTrayResult installOtherDesktopTray(DateTime clock) {
  return const DesktopTrayResult(
    DesktopTrayStatus.inactive,
    detail: 'Desktop tray is Linux-only in P3.1.',
  );
}