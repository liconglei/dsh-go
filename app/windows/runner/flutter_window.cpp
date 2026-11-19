#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

#include "clipboard_channel.h"
#include "window_geometry.h"

namespace {

// Trailing timer id for the geometry write; any non-zero value works.
constexpr UINT_PTR kGeometryTimer = 0xD5;

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
  clipboard_channel_ = CreateClipboardChannel(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
    // Win32Window::Show() always shows normal, so a maximised window from the
    // last session is restored right after it.
    if (start_maximized_) {
      ::ShowWindow(GetHandle(), SW_SHOWMAXIMIZED);
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Drop the channel before its messenger (the engine) goes away.
  clipboard_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Window geometry is bookkeeping for the next launch, not message dispatch:
  // record it before Flutter and the plugins get a chance to consume the
  // message, and never swallow anything here.
  switch (message) {
    case WM_EXITSIZEMOVE:
      ::KillTimer(hwnd, kGeometryTimer);
      WriteGeometry(hwnd);
      break;
    case WM_SIZE:
      // Dragging the frame emits WM_SIZE per frame and every WriteGeometry
      // rewrites window.ini. A trailing timer coalesces that into one write
      // and still catches maximise/restore, which never send WM_EXITSIZEMOVE.
      // Persisting as we go matters because tray exit calls exit(0) and never
      // unwinds main()'s message loop.
      ::SetTimer(hwnd, kGeometryTimer, 500, nullptr);
      break;
    case WM_TIMER:
      if (wparam == kGeometryTimer) {
        ::KillTimer(hwnd, kGeometryTimer);
        WriteGeometry(hwnd);
        return 0;
      }
      break;
  }

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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
