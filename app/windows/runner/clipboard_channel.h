#ifndef RUNNER_CLIPBOARD_CHANNEL_H_
#define RUNNER_CLIPBOARD_CHANNEL_H_

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

namespace flutter {
class FlutterEngine;
}

// Reads an image from the Windows clipboard as PNG bytes. The channel answers
// `imagePng` with a Uint8List, or null when the clipboard holds no image.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateClipboardChannel(flutter::FlutterEngine* engine);

#endif  // RUNNER_CLIPBOARD_CHANNEL_H_
