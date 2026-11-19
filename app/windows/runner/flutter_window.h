#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // Restore the previous session's maximised state. Must be set before Create:
  // Win32Window::Show() always shows normal, so FlutterWindow re-maximises on
  // the first frame itself.
  void SetStartMaximized(bool maximized) { start_maximized_ = maximized; }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Whether the previous session left the window maximised.
  bool start_maximized_ = false;

  // Windows-only: reads images from the system clipboard for the composer.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
