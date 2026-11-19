// Windows desktop clipboard images. Flutter's `onContentInserted` is Android
// only, so the native runner answers `dsh/clipboard` with PNG bytes instead.

import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('dsh/clipboard');

/// The clipboard's image as PNG, or null when it holds none (text, files).
Future<Uint8List?> readClipboardImage() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.windows) return null;
  try {
    final bytes = await _channel.invokeMethod<Uint8List>('imagePng');
    if (bytes != null && bytes.isNotEmpty) return bytes;
  } on MissingPluginException {
    // Runners before the clipboard channel: plain paste still works.
  } catch (_) {}
  return null;
}
