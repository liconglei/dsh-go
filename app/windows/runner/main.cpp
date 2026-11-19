#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include "window_geometry.h"

namespace {

// dsh-go: one instance per user. A second launch activates the existing
// window instead of opening a second client with duplicate long-poll streams.
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\DSH-Go-SingleInstance";
// One literal for both Create and the FindWindow lookup above, so a rename
// cannot silently break single-instance activation.
constexpr wchar_t kWindowTitle[] = L"DSH Go";

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // dsh-go: keep the mutex alive for the whole process; a second launch
  // focuses the first window and exits quietly.
  HANDLE singleton = ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  // A mutex that cannot be created (restricted profile) only costs the
  // single-instance guard; it must not stop the app from starting.
  const bool is_first =
      singleton == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS;
  if (!is_first) {
    HWND existing = ::FindWindowW(nullptr, kWindowTitle);
    if (existing != nullptr) {
      ::ShowWindow(existing, SW_RESTORE);
      ::SetForegroundWindow(existing);
    }
    if (singleton != nullptr) ::ReleaseMutex(singleton);
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  const Geometry geometry = ReadGeometry();
  Win32Window::Point origin(geometry.x, geometry.y);
  Win32Window::Size size(geometry.width, geometry.height);
  window.SetStartMaximized(geometry.maximized);
  if (!window.Create(kWindowTitle, origin, size)) {
    if (singleton != nullptr) ::ReleaseMutex(singleton);
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (singleton != nullptr) ::ReleaseMutex(singleton);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
