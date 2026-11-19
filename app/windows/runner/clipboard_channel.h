#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace flutter {
class FlutterEngine;
}

// Desktop file helpers. The channel answers `imagePng` with the clipboard's
// image as PNG bytes (or null), and `saveImagePng` with the absolute path the
// image was written to under the user's Pictures directory.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateClipboardChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
