// EasyPass Native Messaging Host Bridge (2.0)
//
// Console (x86) bridge that connects the browser's stdio native-messaging
// pipe to the EasyPass background daemon over loopback TCP.
//
// Why this exists: Chrome/Edge launch the manifest "path" binary with stdio
// pipes, but 32-bit Edge has a cross-bitness handle-passing issue that leaves
// the 64-bit Flutter host with a non-pipe stdin (observed: FILE_TYPE_CHAR),
// so the host cannot receive browser messages. A console bridge compiled as
// x86 matches the 32-bit browser's handle inheritance, so its stdin/stdout
// are reliable. It then talks to the daemon (easypass.exe --service), which
// owns the vault database and the unlock state.
//
// Protocol: both ends use the native messaging framing (4-byte little-endian
// length + UTF-8 JSON). The bridge is a pure byte forwarder; it never
// inspects message payloads. The first frame sent to the daemon is the
// handshake {"token":"..."} read from %LOCALAPPDATA%\EasyPass\daemon.json.
//
// Build (x86 console, no MSBuild needed):
//   cl /nologo /O1 /MT /EHsc /Fe:easypass_native_host.exe ^
//       easypass_native_host.cpp ws2_32.lib

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <stdio.h>
#include <string>
#include <vector>

#pragma comment(lib, "ws2_32.lib")

namespace {

// ---- tiny helpers ---------------------------------------------------------

std::wstring Widen(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w(n - 1, 0);
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}

std::string ReadFileText(const std::wstring& path) {
  HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                         OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE) return std::string();
  std::string out;
  char buf[1024];
  DWORD read = 0;
  while (ReadFile(h, buf, sizeof(buf), &read, nullptr) && read > 0) {
    out.append(buf, read);
  }
  CloseHandle(h);
  return out;
}

bool ExtractJsonField(const std::string& json, const std::string& key,
                      std::string* out) {
  // Searches for `"key":` then captures a string or number value. Enough for
  // daemon.json which we control.
  std::string needle = "\"" + key + "\":";
  size_t pos = json.find(needle);
  if (pos == std::string::npos) return false;
  pos += needle.size();
  while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;
  if (pos >= json.size()) return false;
  if (json[pos] == '"') {  // string value
    ++pos;
    std::string v;
    while (pos < json.size() && json[pos] != '"') {
      if (json[pos] == '\\' && pos + 1 < json.size()) ++pos;
      v += json[pos++];
    }
    *out = v;
    return true;
  }
  // number value
  size_t start = pos;
  while (pos < json.size() && (isdigit((unsigned char)json[pos]) || json[pos] == '.')) ++pos;
  if (pos == start) return false;
  *out = json.substr(start, pos - start);
  return true;
}

std::wstring GetExeDir() {
  wchar_t buf[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  std::wstring p(buf);
  size_t slash = p.find_last_of(L"\\/");
  return slash == std::wstring::npos ? L"." : p.substr(0, slash);
}

// ---- frame helpers --------------------------------------------------------

bool ReadExact(HANDLE h, void* buf, DWORD n) {
  char* p = static_cast<char*>(buf);
  DWORD got = 0;
  while (got < n) {
    DWORD chunk = 0;
    if (!ReadFile(h, p + got, n - got, &chunk, nullptr) || chunk == 0) {
      return false;  // EOF or error
    }
    got += chunk;
  }
  return true;
}

bool RecvExact(SOCKET s, void* buf, size_t n) {
  char* p = static_cast<char*>(buf);
  size_t got = 0;
  while (got < n) {
    int chunk = recv(s, p + got, (int)(n - got), 0);
    if (chunk <= 0) return false;
    got += (size_t)chunk;
  }
  return true;
}

// Read one length-prefixed frame from stdin and forward it to the socket.
DWORD WINAPI StdinToSocket(LPVOID param) {
  SOCKET s = reinterpret_cast<SOCKET>(param);
  unsigned char len[4] = {};
  while (ReadExact(GetStdHandle(STD_INPUT_HANDLE), len, 4)) {
    unsigned int size = len[0] | (len[1] << 8) | (len[2] << 16) | (len[3] << 24);
    std::vector<char> body(size);
    if (size > 0 && !ReadExact(GetStdHandle(STD_INPUT_HANDLE), body.data(), size)) break;
    if (send(s, reinterpret_cast<const char*>(len), 4, 0) != 4) break;
    if (size > 0 && send(s, body.data(), size, 0) != (int)size) break;
  }
  shutdown(s, SD_SEND);
  return 0;
}

// Read frames from the socket and forward them to stdout.
DWORD WINAPI SocketToStdout(LPVOID param) {
  SOCKET s = reinterpret_cast<SOCKET>(param);
  HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
  unsigned char len[4] = {};
  while (RecvExact(s, len, 4)) {
    unsigned int size = len[0] | (len[1] << 8) | (len[2] << 16) | (len[3] << 24);
    std::vector<char> body(size);
    if (size > 0 && !RecvExact(s, body.data(), size)) break;
    DWORD written = 0;
    WriteFile(out, len, 4, &written, nullptr);
    if (size > 0) WriteFile(out, body.data(), size, &written, nullptr);
    FlushFileBuffers(out);
  }
  return 0;
}

// ---- daemon connection ----------------------------------------------------

bool LaunchDaemon(const std::wstring& exe_dir) {
  std::wstring cmd = L"\"" + exe_dir + L"\\easypass.exe\" --service";
  STARTUPINFOW si = {sizeof(si)};
  PROCESS_INFORMATION pi = {};
  // NOTE: do NOT pass STARTF_USESHOWWINDOW/SW_HIDE here. Diagnostic testing
  // showed that launching the Flutter app already-hidden makes its engine
  // initialization stall (the Dart code never runs). The app hides its own
  // window after startup (windows/runner/main.cpp), which is safe.
  BOOL ok = CreateProcessW(nullptr, &cmd[0], nullptr, nullptr, FALSE,
                           CREATE_NO_WINDOW, nullptr, exe_dir.c_str(), &si, &pi);
  if (ok) {
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  }
  return ok;
}

// Read daemon.json, launch the daemon if needed, then connect and handshake.
// Returns the connected socket or INVALID_SOCKET.
SOCKET ConnectToDaemon() {
  WSADATA wsa = {};
  WSAStartup(MAKEWORD(2, 2), &wsa);

  std::wstring info_path = GetExeDir() + L"\\daemon.json";
  // Prefer the installed location for daemon.json (written by the daemon
  // under %LOCALAPPDATA%\EasyPass). The exe-dir copy is a fallback for
  // dev/test setups where the daemon was started manually.
  const wchar_t* env = _wgetenv(L"LOCALAPPDATA");
  if (env && *env) {
    std::wstring p = std::wstring(env) + L"\\EasyPass\\daemon.json";
    if (GetFileAttributesW(p.c_str()) != INVALID_FILE_ATTRIBUTES) {
      info_path = p;
    }
  }

  std::string port_str, token;
  auto try_read = [&]() -> bool {
    std::string json = ReadFileText(info_path);
    return ExtractJsonField(json, "port", &port_str) &&
           ExtractJsonField(json, "token", &token);
  };

  auto connect_attempt = [&](int port) -> SOCKET {
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s == INVALID_SOCKET) return INVALID_SOCKET;
    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
    if (connect(s, (sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
      closesocket(s);
      return INVALID_SOCKET;
    }
    return s;
  };

  auto poll_daemon = [&]() -> bool {
    port_str.clear();
    token.clear();
    for (int i = 0; i < 40; ++i) {
      Sleep(250);
      if (try_read()) return true;
    }
    return false;
  };

  SOCKET s = INVALID_SOCKET;
  if (try_read()) {
    // daemon.json exists: try connecting to the recorded port.
    s = connect_attempt(atoi(port_str.c_str()));
  }
  if (s == INVALID_SOCKET) {
    // No daemon or it died (stale daemon.json): clear the stale info and
    // relaunch, then poll until the fresh daemon publishes new coordinates.
    DeleteFileW(info_path.c_str());
    if (!LaunchDaemon(GetExeDir())) return INVALID_SOCKET;
    if (!poll_daemon()) return INVALID_SOCKET;
    s = connect_attempt(atoi(port_str.c_str()));
    if (s == INVALID_SOCKET) return INVALID_SOCKET;
  }

  // Handshake: {"token":"..."} as a length-prefixed frame.
  std::string hs = "{\"token\":\"" + token + "\"}";
  unsigned int n = (unsigned int)hs.size();
  unsigned char len[4] = {(unsigned char)(n & 0xff),
                          (unsigned char)((n >> 8) & 0xff),
                          (unsigned char)((n >> 16) & 0xff),
                          (unsigned char)((n >> 24) & 0xff)};
  send(s, reinterpret_cast<const char*>(len), 4, 0);
  send(s, hs.data(), (int)hs.size(), 0);
  return s;
}

}  // namespace

int main() {
  SOCKET s = ConnectToDaemon();
  if (s == INVALID_SOCKET) {
    fprintf(stderr, "easypass_native_host: cannot reach the EasyPass daemon\n");
    return 1;
  }

  HANDLE t1 = CreateThread(nullptr, 0, StdinToSocket, (LPVOID)s, 0, nullptr);
  HANDLE t2 = CreateThread(nullptr, 0, SocketToStdout, (LPVOID)s, 0, nullptr);

  // The bridge lives as long as the browser connection: stdin EOF or socket
  // close ends both threads. Poll until one finishes, then exit.
  // NOTE: keep the thread handles open -- GetExitCodeThread on a closed
  // handle fails and is mistaken for a finished thread, exiting immediately.
  for (;;) {
    Sleep(500);
    DWORD c1 = 0, c2 = 0;
    if (t1) GetExitCodeThread(t1, &c1);
    if (t2) GetExitCodeThread(t2, &c2);
    if ((t1 && c1 != STILL_ACTIVE) || (t2 && c2 != STILL_ACTIVE)) break;
  }
  if (t1) CloseHandle(t1);
  if (t2) CloseHandle(t2);
  closesocket(s);
  WSACleanup();
  return 0;
}
